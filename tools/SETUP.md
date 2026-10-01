# Toolchain Setup (one time)

The compiler (`sold`) has **no Windows build**, only Linux and macOS, so we use **WSL**
(Ubuntu inside Windows). `tvm-cli` does have a Windows build, but keeping both tools in
WSL means one environment.

## 1. Install WSL — you run this (it changes Windows features)

In **PowerShell as Administrator**:

```
wsl --install -d Ubuntu
```

Reboot when asked, open **Ubuntu** from the Start menu, create your Linux username and password.

## 2. Install the tools — inside Ubuntu

```
mkdir -p ~/tools && cd ~/tools
curl -fsSLO https://github.com/gosh-sh/TVM-Solidity-Compiler/releases/download/gosh_0.81.0/sold_gosh_0.81.0_linux_x86_64.tar.gz
curl -fsSLO https://github.com/tvmlabs/tvm-sdk/releases/download/v3.0.6.an/tvm-cli-3.0.6.an-linux-musl-amd64.tar.gz
tar xzf sold_gosh_0.81.0_linux_x86_64.tar.gz
tar xzf tvm-cli-3.0.6.an-linux-musl-amd64.tar.gz
ls -R ~/tools
```

Find where the `sold` and `tvm-cli` binaries landed, then put that folder on your PATH
(if they are directly in `~/tools`, this is enough):

```
echo 'export PATH="$HOME/tools:$PATH"' >> ~/.bashrc && source ~/.bashrc
sold --version
tvm-cli --version
```

| File | Size | Source |
|---|---|---|
| `sold_gosh_0.81.0_linux_x86_64.tar.gz` | ~4.8 MB | github.com/gosh-sh/TVM-Solidity-Compiler (the team behind dexdo) |
| `tvm-cli-3.0.6.an-linux-musl-amd64.tar.gz` | ~9.1 MB | github.com/tvmlabs/tvm-sdk (linked from dev.ackinacki.com) |

## 3. Point tvm-cli at Shellnet

```
tvm-cli config -g --url shellnet.ackinacki.org
```

## 4. Giver ABI

```
cd ~/tools && curl -fsSLO https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/giver/GiverV3.abi.json
```

The Shellnet giver is `0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111`.
It sends native vmshell plus **NACKL (1), SHELL (2) and USDC (3)**, with per-call caps.
Methods: `sendCurrency(dest, value, ecc)` and `sendCurrencyWithFlag(dest, value, ecc, flag)`.

## 5. A throwaway Shellnet key

```
cd <repo>
tvm-cli genphrase --dump spike.keys.json
```

(If that flag differs in this version, see `tvm-cli genphrase --help`.)

**Shellnet only.** Never use this key on mainnet, and never put a mainnet key in this folder.
`.gitignore` already excludes `*.keys.json`.

## Where the project is from WSL

Windows `C:` is `/mnt/c`, so the project lives at
`<repo>`.
