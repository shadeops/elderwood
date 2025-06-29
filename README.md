# Elderwood Playdate Demo

## Overview
Technical demo using Houdini and Zig to create a game world on the Playdate.

##  <a name="Requirements"></a>Requirements
- Either macOS, Windows, or Linux.
- Zig compiler 0.14.x series. Pulling down the [latest build from master](https://ziglang.org/download/) is your best bet.
- [Playdate SDK](https://play.date/dev/) 2.7.3 or later installed.

## Run Code
1. Make sure the Playdate SDK is installed, Zig is installed and in your PATH, and all other [requirements](#Requirements) are met.
1. Make sure the Playdate Simulator is closed.
1. Run `zig build run`.
    1. If there any errors, double check `PLAYDATE_SDK_PATH` is correctly set.

## Acknowledgements
- This project uses the [Zig Playdate Template](https://github.com/DanB91/Zig-Playdate-Template)

