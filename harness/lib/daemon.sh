# shellcheck shell=bash
# harness/lib/daemon.sh — logoscore daemon lifecycle + the node_call seam.
# W1-A ports daemon boot/poll/load-module from the modules-repo e2e script.
# node_call has the same signature whether the node is a host process (now) or
# a container (compose topology, P3) — scenarios never know the difference.

daemon_start()        { die "daemon.sh: not implemented yet (W1-A)"; }
daemon_load_modules() { die "daemon.sh: not implemented yet (W1-A)"; }
daemon_stop()         { die "daemon.sh: not implemented yet (W1-A)"; }
node_call()           { die "daemon.sh: not implemented yet (W1-A)"; }  # <node> <module> <method> [args…]
node_logs()           { die "daemon.sh: not implemented yet (W1-A)"; }