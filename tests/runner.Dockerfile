# The environment tests/run.sh runs in: the tools Katap needs on a host (bash 5,
# flock, git, jq, openssl, the Docker CLI and Compose), ssh-keygen for the action's
# host-key check, plus shellcheck and python3 for the stub server. Running every test in it means a developer's macOS bash 3.2 or
# missing flock can never make a test pass or fail differently from the server.
FROM docker:29.9.0-cli@sha256:1a4c7cb63513f349bdad01fcc6e0f3f2f67d37b9da86f14dc0d4a0942eecda00

RUN apk add --no-cache bash coreutils curl git jq openssh-keygen openssl python3 shellcheck util-linux
