// A development run of the shell that never shows anything (hidden-electron.cjs): the hook, then the real main.
require("./hidden-hook.cjs");
require("./main.cjs");
