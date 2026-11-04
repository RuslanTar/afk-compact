// GEN by tools/fixtures-gen from tests/fixtures. Do not edit; edit the fixtures and run tools/fixtures-gen.
// paths/junk-paths.json: recorded temp paths and whether their text marks a piece of a command
export type JunkPathRow = { path: string; as: string; junk: boolean; why: string }
export const JUNK_PATHS: readonly JunkPathRow[] = [
 {
  "path": "/tmp/run/real.txt",
  "as": "/tmp/run/real.txt",
  "junk": false,
  "why": "a plain absolute path"
 },
 {
  "path": "/private/tmp/a/tasks/b7e1c2a9.output",
  "as": "/private/tmp/a/tasks/b7e1c2a9.output",
  "junk": false,
  "why": "a task output"
 },
 {
  "path": "$S/tasks/wm9kfyrdx.output",
  "as": "$S/tasks/wm9kfyrdx.output",
  "junk": true,
  "why": "not absolute: an unexpanded variable first"
 },
 {
  "path": "tasks/wm9kfyrdx.output",
  "as": "tasks/wm9kfyrdx.output",
  "junk": true,
  "why": "not absolute"
 },
 {
  "path": "/tmp/run/*",
  "as": "/tmp/run/*",
  "junk": true,
  "why": "a glob"
 },
 {
  "path": "/tmp/run/[ab].log",
  "as": "/tmp/run/[ab].log",
  "junk": true,
  "why": "a glob class"
 },
 {
  "path": "/tmp/run/{a,b}.log",
  "as": "/tmp/run/{a,b}.log",
  "junk": true,
  "why": "a brace pattern"
 },
 {
  "path": "/var/folders/.../T",
  "as": "/var/folders/.../T",
  "junk": true,
  "why": "an elided part"
 },
 {
  "path": "/tmp/a...b/c",
  "as": "/tmp/a...b/c",
  "junk": false,
  "why": "three dots inside a name are a name"
 },
 {
  "path": "/tmp/run/v012-${l.k}-answers/.\\n${RULES}\\nReport",
  "as": "/tmp/run/v012-${l.k}-answers/.\\n${RULES}\\nReport",
  "junk": true,
  "why": "a template variable and an escaped newline"
 },
 {
  "path": "/tmp/ppost.$$",
  "as": "/tmp/ppost.$$",
  "junk": true,
  "why": "the shell's pid variable"
 },
 {
  "path": "/tmp/cost$",
  "as": "/tmp/cost$",
  "junk": true,
  "why": "a variable cut at the end"
 },
 {
  "path": "F=/tmp/run/real2.txt",
  "as": "/tmp/run/real2.txt",
  "junk": false,
  "why": "a shell assignment taken off"
 },
 {
  "path": "exit:/tmp/run/real2.txt",
  "as": "/tmp/run/real2.txt",
  "junk": false,
  "why": "a wait spec taken off"
 },
 {
  "path": "F=$S/tasks/x.output",
  "as": "F=$S/tasks/x.output",
  "junk": true,
  "why": "an assignment of a variable path: nothing to take off, not absolute"
 },
 {
  "path": "/private/tmp/flow-guard-",
  "as": "/private/tmp/flow-guard-",
  "junk": true,
  "why": "a prefix cut at a variable"
 },
 {
  "path": "/var/folders/x1/T/flow-0331-",
  "as": "/var/folders/x1/T/flow-0331-",
  "junk": true,
  "why": "a prefix cut at a variable"
 },
 {
  "path": "/tmp/cmb-",
  "as": "/tmp/cmb-",
  "junk": true,
  "why": "a prefix cut at a variable"
 },
 {
  "path": "/tmp/run/x-1",
  "as": "/tmp/run/x-1",
  "junk": false,
  "why": "a dash inside a name"
 },
 {
  "path": "/tmp/run-/x",
  "as": "/tmp/run-/x",
  "junk": false,
  "why": "a dash at the end of a folder, not of the path"
 },
 {
  "path": "/private/tmp/claude-%d",
  "as": "/private/tmp/claude-%d",
  "junk": true,
  "why": "a printf directive"
 },
 {
  "path": "/tmp/out-%s.log",
  "as": "/tmp/out-%s.log",
  "junk": true,
  "why": "a printf directive"
 },
 {
  "path": "/tmp/frame%05.2f.png",
  "as": "/tmp/frame%05.2f.png",
  "junk": true,
  "why": "a printf directive with flag, width and precision"
 },
 {
  "path": "/tmp/a%-3d",
  "as": "/tmp/a%-3d",
  "junk": true,
  "why": "a printf directive with flag and width"
 },
 {
  "path": "/tmp/a%+i",
  "as": "/tmp/a%+i",
  "junk": true,
  "why": "a printf directive"
 },
 {
  "path": "/tmp/a%#x",
  "as": "/tmp/a%#x",
  "junk": true,
  "why": "a printf directive"
 },
 {
  "path": "/tmp/a% X",
  "as": "/tmp/a% X",
  "junk": true,
  "why": "a printf directive with a space flag"
 },
 {
  "path": "/tmp/a%c%u",
  "as": "/tmp/a%c%u",
  "junk": true,
  "why": "printf directives"
 },
 {
  "path": "/tmp/a%20b",
  "as": "/tmp/a%20b",
  "junk": false,
  "why": "a URL escape is no directive"
 },
 {
  "path": "/tmp/100%",
  "as": "/tmp/100%",
  "junk": false,
  "why": "a percent sign alone"
 },
 {
  "path": "/tmp/a%.log",
  "as": "/tmp/a%.log",
  "junk": false,
  "why": "a percent sign before a dot and no conversion"
 }
]
