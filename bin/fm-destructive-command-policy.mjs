#!/usr/bin/env node
// Semantic policy for the destructive-command guard: is a shell command a
// destructive bulk delete that no worker or mate pane may run on its own care?
//
// A worker once deleted about 370 shared docker workspace volumes with a cleanup
// filter that carried one stray extra pattern. A rule written in a brief did not
// stop it, so this policy denies the command shape itself before it runs. See
// docs/destructive-guard.md for the complete contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy never
// evaluates, expands, sources, or runs any byte of the submitted command; it
// inspects lexical command positions only. The transport
// (bin/fm-destructive-pretool-check.sh) owns identity, the override, logging,
// and the harness output; this file owns only the allow/deny decision.

import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const REASONS = {
  "docker-prune":
    "a docker or podman prune deletes every matching resource on the host, including shared ones this pane did not create",
  "docker-bulk-rm":
    "a docker or podman removal whose targets come from a filter, wildcard, variable, command substitution, xargs, or a pipe can delete resources this pane did not create",
  "docker-rm-unowned":
    "a docker or podman removal may name only resources that carry this pane's own task label; this name does not, so it may belong to someone else",
  "rm-glob-protected":
    "a recursive rm over a wildcard or variable path under the home directory or /mnt can sweep shared state; only this pane's own worktree and /tmp are open to it",
  "rm-protected-root":
    "a recursive rm of the home directory, a shared top-level directory under it, /mnt, or / is never a cleanup",
  "rm-bulk-piped":
    "an rm fed by xargs or a pipe deletes a list nobody reviewed",
  "find-delete":
    "find with -delete or -exec rm may run only under /tmp/fm-*; elsewhere it deletes a list nobody reviewed",
  "git-clean":
    "git clean -f deletes untracked and ignored work; it may run only inside the worktree spawned for this pane",
  "device-write":
    "writing, formatting, wiping, or repartitioning a block device is irreversible",
  "btrfs-subvolume-delete":
    "deleting a btrfs subvolume is irreversible",
  "systemctl-disable":
    "disabling or masking a systemd unit changes host services that fleet-ops manages",
  "unclassifiable-destructive":
    "the command uses shell syntax this guard cannot classify and mentions a destructive command",
};

const MAX_DEPTH = 8;
const DOCKER_CLIS = new Set(["docker", "podman", "nerdctl"]);
const DOCKER_GLOBAL_ARG_OPTIONS = new Set([
  "-H", "--host", "-c", "--context", "--config", "-l", "--log-level",
  "--tlscacert", "--tlscert", "--tlskey", "--connection", "--url", "--identity",
  "--root", "--runroot", "--namespace", "-n", "--address", "-a",
]);
const DOCKER_OBJECTS = new Set(["volume", "container", "image", "network", "system", "builder", "buildx"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh"]);
const SHELL_KEYWORDS = new Set(["do", "then", "else", "elif", "if", "while", "until", "!", "time"]);
const EXTRA_WRAPPERS = {
  nice: new Set(["-n", "--adjustment"]),
  ionice: new Set(["-c", "-n", "-p", "-P", "-u", "--class", "--classdata"]),
  setsid: new Set(),
  stdbuf: new Set(["-i", "-o", "-e"]),
  doas: new Set(["-u", "-C"]),
  chrt: new Set(),
  flock: new Set(["-w", "-E", "--timeout", "--conflict-exit-code"]),
};
const XARGS_ARG_OPTIONS = new Set(["-I", "-i", "-n", "-P", "-L", "-l", "-d", "-E", "-e", "-s", "-a", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--max-lines", "--max-chars", "--replace", "--eof", "--process-slot-var"]);
const SSH_ARG_OPTIONS = new Set(["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w", "-B", "-P"]);
const DEVICE_TOOLS = new Set(["mkfs", "mke2fs", "mkswap", "wipefs", "blkdiscard", "parted", "fdisk", "sfdisk", "sgdisk", "gdisk", "cfdisk", "shred"]);
const PARTITION_LISTERS = new Set(["parted", "fdisk", "sfdisk", "sgdisk", "gdisk"]);
const DEV_SAFE = /^\/dev\/(?:null|zero|stdout|stderr|stdin|tty|fd\/.*|full|random|urandom)$/;
const FIND_EXEC = new Set(["-exec", "-execdir", "-ok", "-okdir"]);
const FIND_EXEC_DELETERS = new Set(["rm", "rmdir", "unlink", "shred", "docker", "podman", "nerdctl"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// Raw backstop for syntax the shared tokenizer refuses (case arms, unbalanced
// quoting): fail closed only when a destructive verb is visibly present.
function rawLooksDestructive(command) {
  const text = command.replace(/\\\r?\n/g, "");
  return [
    /\b(?:docker|podman|nerdctl)\b[\s\S]*\b(?:prune|rm|rmi|remove)\b/,
    /\brm\b[\s\S]*(?:\s-[A-Za-z]*[rR]|--recursive)/,
    /\bfind\b[\s\S]*(?:-delete|-exec(?:dir)?\s+\S*\brm\b)/,
    /\b(?:mkfs(?:\.\w+)?|mke2fs|mkswap|wipefs|blkdiscard|parted|sfdisk|sgdisk)\b/,
    /\bdd\b[\s\S]*\bof=\/dev\//,
    /\bbtrfs\b[\s\S]*\bsub\w*\s+d/,
    /\bsystemctl\b[\s\S]*\b(?:disable|mask)\b/,
    /\bgit\b[\s\S]*\bclean\b/,
  ].some((pattern) => pattern.test(text));
}

function isWord(token) {
  return token && token.type === "word";
}

function dynamicWord(word) {
  return !word.literal || word.subs.length > 0;
}

function globWord(word) {
  if (!word.unquotedExpansion) return false;
  return /[*?[]/.test(word.value) || /\{[^}]*,[^}]*\}/.test(word.value) || /\{[^}]*\.\.[^}]*\}/.test(word.value);
}

function within(child, parent) {
  if (!child || !parent) return false;
  const relative = path.relative(parent, child);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

// Resolve the static location a target word names, without expanding anything
// but a leading ~ or $HOME. Returns { location, pattern }: location is the
// absolute static directory prefix, or null when it cannot be known; pattern is
// true when the word carries a wildcard or any other expansion.
function targetLocation(word, context) {
  if (word.subs.length > 0) return { location: null, pattern: true };
  let value = word.value;
  if (value === "~" || value.startsWith("~/")) value = context.home + value.slice(1);
  else if (/^\$(?:HOME\b|\{HOME\})/.test(value)) value = context.home + value.replace(/^\$(?:HOME|\{HOME\})/, "");
  const glob = globWord(word);
  const dynamic = value.includes("$");
  const pattern = glob || dynamic;
  let prefix = value;
  if (pattern) {
    const cut = value.search(glob ? /[$*?[{]/ : /\$/);
    prefix = cut === -1 ? value : value.slice(0, cut);
    if (!prefix.endsWith("/")) prefix = prefix.includes("/") ? prefix.slice(0, prefix.lastIndexOf("/") + 1) : "";
  }
  if (!path.isAbsolute(prefix)) {
    if (pattern && prefix === "" && value.startsWith("$")) return { location: null, pattern };
    if (!context.cwd) return { location: null, pattern };
    prefix = path.resolve(context.cwd, prefix || ".");
  }
  return { location: path.normalize(prefix), pattern };
}

function protectedRoots(home) {
  const roots = ["/", "/home", "/mnt", "/media", "/srv"];
  if (home) {
    for (const child of ["", ".local", ".local/state", ".local/share", ".treehouse", "Documents", "backups", "src", "cloud", ".config", ".ssh"]) {
      roots.push(path.join(home, child));
    }
  }
  return roots.map((root) => path.normalize(root));
}

function isProtectedRoot(location, context) {
  if (protectedRoots(context.home).includes(location)) return true;
  if (path.dirname(location) === "/mnt") return true;
  if (context.home) {
    const treehouse = path.join(context.home, ".treehouse");
    const relative = path.relative(treehouse, location);
    if (relative && !relative.startsWith("..") && relative.split("/").length <= 2 && !within(location, context.ownWorktree)) return true;
  }
  return false;
}

function inSharedTree(location, context) {
  if (location === "/") return true;
  for (const root of ["/mnt", "/home", "/media", "/srv"]) if (within(location, root)) return true;
  return Boolean(context.home) && within(location, context.home);
}

function findRootOpen(location, context) {
  if (!/^\/tmp\/fm-[^/]+/.test(location)) return false;
  return !(context.home && within(location, context.home));
}

function ownsName(name, context) {
  return context.ownLabels.some((label) => label.length >= 3 && name.includes(label));
}

// --- per-command classifiers --------------------------------------------------

function classifyDocker(words, start, context, fed) {
  let index = start;
  while (index < words.length && words[index].value.startsWith("-")) {
    const option = words[index].value;
    if (!option.includes("=") && DOCKER_GLOBAL_ARG_OPTIONS.has(option)) index += 2;
    else index += 1;
  }
  const sub = words[index]?.value;
  if (!sub) return null;
  let objectKind = "container";
  let verbIndex = index;
  if (DOCKER_OBJECTS.has(sub)) {
    objectKind = sub;
    verbIndex = index + 1;
    while (verbIndex < words.length && words[verbIndex].value.startsWith("-")) verbIndex += 1;
  } else if (sub === "rmi") {
    objectKind = "image";
  }
  const verb = words[verbIndex]?.value;
  if (!verb) return null;
  if (verb === "prune") {
    if (objectKind === "builder" || objectKind === "buildx") return null;
    return deny("docker-prune");
  }
  const removal = (verbIndex === index && (verb === "rm" || verb === "rmi")) ||
    (verbIndex !== index && (verb === "rm" || verb === "remove") && objectKind !== "system");
  if (!removal) return null;
  if (fed) return deny("docker-bulk-rm");
  const targets = [];
  for (let i = verbIndex + 1; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-a" || value === "--all" || value.startsWith("--filter")) return deny("docker-bulk-rm");
    if (value.startsWith("-")) continue;
    targets.push(words[i]);
  }
  for (const target of targets) {
    if (dynamicWord(target) || globWord(target) || /[*?[]/.test(target.value)) return deny("docker-bulk-rm");
  }
  for (const target of targets) {
    if (!ownsName(target.value, context)) return deny("docker-rm-unowned");
  }
  return null;
}

function classifyRm(words, start, context, fed) {
  let recursive = false;
  const targets = [];
  let optionsEnded = false;
  for (let i = start; i < words.length; i += 1) {
    const value = words[i].value;
    if (!optionsEnded && value === "--") {
      optionsEnded = true;
      continue;
    }
    if (!optionsEnded && value.startsWith("--")) {
      if (value === "--recursive") recursive = true;
      if (value === "--no-preserve-root") return deny("rm-protected-root");
      continue;
    }
    if (!optionsEnded && value.startsWith("-") && value.length > 1) {
      if (/[rR]/.test(value.slice(1))) recursive = true;
      continue;
    }
    targets.push(words[i]);
  }
  if (fed) return deny("rm-bulk-piped");
  if (!recursive) return null;
  for (const target of targets) {
    const { location, pattern } = targetLocation(target, context);
    if (!pattern) {
      if (location && isProtectedRoot(location, context)) return deny("rm-protected-root");
      continue;
    }
    if (!location) {
      if (globWord(target)) return deny("rm-glob-protected");
      continue;
    }
    if (context.ownWorktree && within(location, context.ownWorktree)) continue;
    if (isProtectedRoot(location, context) || (context.home && within(location, context.home))) return deny("rm-glob-protected");
    if (within(location, "/tmp")) continue;
    if (inSharedTree(location, context)) return deny("rm-glob-protected");
  }
  return null;
}

function classifyFind(words, start, context) {
  let index = start;
  while (index < words.length && /^-(?:H|L|P|O\d*)$/.test(words[index].value)) index += 1;
  if (words[index]?.value === "-D") index += 2;
  const starts = [];
  while (index < words.length && !/^[-(!,]/.test(words[index].value)) {
    starts.push(words[index]);
    index += 1;
  }
  let destructive = false;
  for (let i = index; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-delete") destructive = true;
    if (FIND_EXEC.has(value) && words[i + 1] && FIND_EXEC_DELETERS.has(basename(words[i + 1].value))) destructive = true;
  }
  if (!destructive) return null;
  const roots = starts.length > 0 ? starts : null;
  if (!roots) return context.cwd && findRootOpen(context.cwd, context) ? null : deny("find-delete");
  for (const root of roots) {
    const { location, pattern } = targetLocation(root, context);
    if (!location || !findRootOpen(location, context)) return deny("find-delete");
  }
  return null;
}

function classifyGit(words, start, context) {
  let index = start;
  let directory = context.cwd;
  while (index < words.length && words[index].value.startsWith("-")) {
    const option = words[index].value;
    if (option === "-C") {
      const target = words[index + 1];
      if (!target || (dynamicWord(target) && !/^\$(?:HOME|\{HOME\})(?:\/|$)/.test(target.value))) directory = null;
      else directory = targetLocation(target, { ...context, cwd: directory }).location;
      index += 2;
      continue;
    }
    if (option === "-c" || option === "--git-dir" || option === "--work-tree" || option === "--namespace") {
      if (option === "--git-dir" || option === "--work-tree") directory = null;
      index += 2;
      continue;
    }
    if (option.startsWith("--git-dir=") || option.startsWith("--work-tree=")) directory = null;
    index += 1;
  }
  if (words[index]?.value !== "clean") return null;
  let force = false;
  let dry = false;
  for (let i = index + 1; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "--") break;
    if (value === "--force") force = true;
    else if (value === "--dry-run" || value === "--interactive") dry = true;
    else if (/^-[A-Za-z]+$/.test(value)) {
      if (value.includes("f")) force = true;
      if (value.includes("n") || value.includes("i")) dry = true;
    }
  }
  if (!force || dry) return null;
  if (directory && context.ownWorktree && within(path.resolve(directory), context.ownWorktree)) return null;
  return deny("git-clean");
}

function classifyDevice(name, words, start) {
  const args = words.slice(start).map((word) => word.value);
  if (name === "dd") {
    return args.some((arg) => arg.startsWith("of=/dev/") && !DEV_SAFE.test(arg.slice(3))) ? deny("device-write") : null;
  }
  const deviceArg = args.some((arg) => {
    const value = arg.includes("=") ? arg.slice(arg.indexOf("=") + 1) : arg;
    return value.startsWith("/dev/") && !DEV_SAFE.test(value);
  });
  if (!deviceArg) return null;
  if (PARTITION_LISTERS.has(name) && args.some((arg) => ["-l", "--list", "-p", "--print", "print"].includes(arg))) return null;
  if (name === "wipefs" && args.some((arg) => arg === "-n" || arg === "--no-act")) return null;
  return deny("device-write");
}

function classifyBtrfs(words, start) {
  const args = words.slice(start).map((word) => word.value).filter((value) => !value.startsWith("-"));
  const [group, verb] = args;
  if (!group || !verb) return null;
  if (group.length >= 2 && "subvolume".startsWith(group) && "delete".startsWith(verb)) return deny("btrfs-subvolume-delete");
  return null;
}

function classifySystemctl(words, start) {
  for (let i = start; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-H" || value === "-M" || value === "--host" || value === "--machine" || value === "-t" || value === "--type" || value === "-p" || value === "--property") {
      i += 1;
      continue;
    }
    if (value.startsWith("-")) continue;
    return value === "disable" || value === "mask" ? deny("systemctl-disable") : null;
  }
  return null;
}

// --- nested execution sinks --------------------------------------------------

function shellPayload(words, start) {
  for (let i = start; i < words.length; i += 1) {
    const value = words[i].value;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(value)) {
      let payload = words[i + 1];
      if (payload?.value === "--") payload = words[i + 2];
      if (!payload || payload.subs.length > 0) return { kind: "none" };
      return { kind: "command", payload: payload.value };
    }
    if (/^[-+]O$/.test(value)) {
      i += 1;
      continue;
    }
    if (value.startsWith("-") || value.startsWith("+")) continue;
    return { kind: "script" };
  }
  return { kind: "stdin" };
}

function sshRemoteCommand(words, start) {
  let index = start;
  while (index < words.length && words[index].value.startsWith("-")) {
    const option = words[index].value;
    index += SSH_ARG_OPTIONS.has(option) ? 2 : 1;
  }
  index += 1; // destination
  const remote = words.slice(index);
  if (remote.length === 0) return "";
  return remote.map((word) => word.value).join(" ");
}

function stripExtraWrappers(words, index) {
  let next = index;
  let fed = false;
  for (;;) {
    const command = words[next];
    if (!command) return { index: next, fed };
    const name = basename(command.value);
    if (name === "xargs" || name === "parallel") {
      fed = true;
      next += 1;
      while (words[next] && words[next].value.startsWith("-")) {
        const option = words[next].value;
        next += XARGS_ARG_OPTIONS.has(option) ? 2 : 1;
      }
      const after = commandPosition(words.slice(next));
      next += after.index;
      continue;
    }
    if (Object.hasOwn(EXTRA_WRAPPERS, name)) {
      const takesArgument = EXTRA_WRAPPERS[name];
      next += 1;
      while (words[next] && words[next].value.startsWith("-")) {
        next += takesArgument.has(words[next].value) ? 2 : 1;
      }
      if (name === "chrt" && words[next] && /^\d+$/.test(words[next].value)) next += 1;
      if (name === "flock" && words[next]) next += 1;
      const after = commandPosition(words.slice(next));
      next += after.index;
      continue;
    }
    return { index: next, fed };
  }
}

// --- program walk ------------------------------------------------------------

function analyze(command, context, depth) {
  if (depth > MAX_DEPTH) return rawLooksDestructive(command) ? deny("unclassifiable-destructive") : null;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return rawLooksDestructive(command) ? deny("unclassifiable-destructive") : null;
  const { nodes, separators } = splitProgram(lexed.tokens);
  let local = { ...context };
  for (let index = 0; index < nodes.length; index += 1) {
    const tokens = nodes[index];
    const piped = isPipe(separators[index - 1]);
    for (const token of tokens) {
      if (token.type === "group") {
        const verdict = analyze(token.content, local, depth + 1);
        if (verdict) return verdict;
      }
      if (token.type === "word") {
        for (const sub of token.subs) {
          const verdict = analyze(sub.content, local, depth + 1);
          if (verdict) return verdict;
        }
      }
    }
    let trimmed = tokens;
    while (isWord(trimmed[0]) && SHELL_KEYWORDS.has(trimmed[0].value)) trimmed = trimmed.slice(1);
    const position = commandPosition(trimmed);
    const { words } = position;
    const stripped = stripExtraWrappers(words, position.index);
    const commandWord = words[stripped.index];
    if (!commandWord) continue;
    const name = basename(commandWord.value);
    const start = stripped.index + 1;
    const fed = stripped.fed || piped;
    let verdict = null;
    if (DOCKER_CLIS.has(name)) verdict = classifyDocker(words, start, local, fed);
    else if (name === "rm") verdict = classifyRm(words, start, local, stripped.fed);
    else if (name === "find") verdict = classifyFind(words, start, local);
    else if (name === "git") verdict = classifyGit(words, start, local);
    else if (name === "dd" || DEVICE_TOOLS.has(name) || name.startsWith("mkfs.")) verdict = classifyDevice(name.startsWith("mkfs.") ? "mkfs" : name, words, start);
    else if (name === "btrfs") verdict = classifyBtrfs(words, start);
    else if (name === "systemctl") verdict = classifySystemctl(words, start);
    else if (SHELLS.has(name)) {
      const payload = shellPayload(words, start);
      if (payload.kind === "command") verdict = analyze(payload.payload, local, depth + 1);
      if (payload.kind === "stdin") {
        for (let i = 0; i < tokens.length && !verdict; i += 1) {
          const token = tokens[i];
          if (token.type === "redir" && typeof token.heredoc === "string") verdict = analyze(token.heredoc, local, depth + 1);
          if (token.type === "redir" && token.value === "<<<" && isWord(tokens[i + 1])) verdict = analyze(tokens[i + 1].value, local, depth + 1);
        }
      }
    } else if (name === "eval") {
      verdict = analyze(words.slice(start).map((word) => word.value).join(" "), local, depth + 1);
    } else if (name === "ssh") {
      const remote = sshRemoteCommand(words, start);
      if (remote) verdict = analyze(remote, { ...local, cwd: local.home, ownWorktree: null }, depth + 1);
    } else if (name === "cd" && !piped && separators[index] !== "&") {
      const target = words[start];
      if (!target) local = { ...local, cwd: local.home };
      else if (dynamicWord(target) && !/^\$(?:HOME|\{HOME\})(?:\/|$)/.test(target.value)) local = { ...local, cwd: null };
      else {
        const { location } = targetLocation(target, local);
        local = { ...local, cwd: location };
      }
    }
    if (verdict) return verdict;
  }
  return null;
}

export function decision(command, options = {}) {
  const context = {
    cwd: options.cwd ? path.resolve(options.cwd) : null,
    home: options.home ? path.resolve(options.home) : "",
    ownWorktree: options.ownWorktree ? path.resolve(options.ownWorktree) : null,
    ownLabels: (options.ownLabels || []).filter(Boolean),
  };
  const verdict = analyze(command, context, 0);
  return verdict || { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, cwd: "", home: "", ownWorktree: "", ownLabels: [] };
  const valued = { "--command": "command", "--cwd": "cwd", "--home": "home", "--own-worktree": "ownWorktree", "--own-label": "ownLabel" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const key = valued[name];
    if (!key) throw new Error(`unknown argument: ${name}`);
    if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
    const value = argv[i + 1];
    i += 1;
    if (key === "ownLabel") result.ownLabels.push(value);
    else result[key] = value;
    if (key === "command") result.commandSet = true;
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args);
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
