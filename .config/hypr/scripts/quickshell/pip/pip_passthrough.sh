#!/usr/bin/env bash
# Toggle the PiP player's non-interactive (click-through) mode.
# Sends SIGUSR1 to pip_player.py, which empties/restores the window input mask.
pkill -USR1 -f "pip/pip_player.py"
