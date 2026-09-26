# gines-forge — releases

Canal **público** de distribuição do daemon `gines-forge` (o código continua privado em `gines-ai/gines-forge`).

Cada release traz:

- `gines-forge-<versão>-x86_64-linux.tar.gz` — instalação autocontida (CPython próprio, dependências com hash, e os CLIs `claude` e `codex` com que a suíte rodou);
- `gines-forge-<versão>-x86_64-linux.tar.gz.sha256`;
- `latest.json` — `{ "version", "file", "sha256", "url", "published_at", "notes_url" }`, o que o daemon lê para se atualizar sozinho.

## Instalar (sem root)

```sh
curl -fsSL https://raw.githubusercontent.com/gines-ai/gines-forge-releases/main/install.sh | sh
```

Instala em `~/.local/share/gines-forge/versions/<versão>/` com o link `current`, o serviço de usuário `gines-forged` e os wrappers em `~/.local/bin`. Depois disso o próprio daemon verifica este canal, baixa a versão nova, confere o `sha256` e reinicia quando estiver ocioso — o mesmo modelo do Claude Code. Publicação: o CI privado empurra um branch `publish/v<versão>-<run>` com o pacote partido; o `publish.yml` daqui remonta, confere e cria a release.
