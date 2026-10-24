set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact without running it')]
check:
    zig build check

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Format build.zig and every source file')]
fmt:
    zig fmt build.zig src tools

[doc('Run a fuzzer: just fuzz <fuzzer> [seed] [events]')]
fuzz *arguments:
    zig build fuzz -- {{ arguments }}

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Regenerate src/profile/ from tools/Profile.xlsx')]
profile:
    zig build profile

[doc('Dump a FIT file: just run <path>')]
run *arguments:
    zig build run -- {{ arguments }}

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just unit [filter]')]
unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
