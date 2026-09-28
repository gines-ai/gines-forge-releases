#!/bin/sh
# SPDX-License-Identifier: LicenseRef-Gines-Proprietary
# Instala (ou atualiza) o gines-forge SEM root, no estilo do instalador do Claude Code:
#
#   ~/.local/share/gines-forge/versions/<versão>/   a instalação autocontida (CPython, deps, claude, codex)
#   ~/.local/share/gines-forge/current -> versions/<versão>
#   ~/.local/bin/gines-forged, ~/.local/bin/forge-cli
#   ~/.config/systemd/user/gines-forged.service     serviço de USUÁRIO
#
# Uso:  curl -fsSL https://raw.githubusercontent.com/gines-ai/gines-forge-releases/main/install.sh | sh
#       GINES_FORGE_VERSION=0.45.0 sh install.sh      # uma versão específica
# Depois disto o próprio daemon se atualiza por este canal (latest.json assinado) e reinicia quando ocioso.
#
# Autenticidade (gines-forge >= 0.47.0): cada pacote tem um <arquivo>.sig com a assinatura ed25519 da
# release e o certificado da chave que assinou, assinado pela RAIZ do operador (publica abaixo). O pacote so
# e instalado se a cadeia raiz -> certificado -> release conferir, com tamanho e sha256 iguais aos assinados.
# Versoes antigas, sem assinatura: so com GINES_FORGE_ALLOW_UNSIGNED=1 (e um aviso).
set -eu

# Publicas da RAIZ (base64, 32 bytes), separadas por espaco. As mesmas de forge/security/release_sig.py.
RAIZES="${GINES_FORGE_RAIZES:-5buYJRR6USIIaq9lYoHApGtWPf2cwWaAXiB2VunN7h0=}"

CANAL="${GINES_FORGE_CHANNEL:-https://github.com/gines-ai/gines-forge-releases}"
RAW="${GINES_FORGE_RAW:-https://raw.githubusercontent.com/gines-ai/gines-forge-releases/main}"
BASE="${XDG_DATA_HOME:-$HOME/.local/share}/gines-forge"
BIN="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

for f in curl tar sha256sum openssl base64; do command -v "$f" >/dev/null 2>&1 || { echo "preciso de $f" >&2; exit 1; }; done
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "so Linux x86_64 por enquanto ($(uname -s)-$(uname -m))" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -n "${GINES_FORGE_VERSION:-}" ]; then
  VERSAO="$GINES_FORGE_VERSION"
  ARQ="gines-forge-$VERSAO-x86_64-linux.tar.gz"
  URL="$CANAL/releases/download/v$VERSAO/$ARQ"
  SHA=assinado
else
  curl -fsSL --retry 3 -o "$TMP/latest.json" "$RAW/latest.json"
  # sem jq: os campos sao simples
  campo() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$TMP/latest.json" | head -1; }
  VERSAO=$(campo version); ARQ=$(campo file); SHA=$(campo sha256); URL=$(campo url)
fi
[ -n "$VERSAO" ] && [ -n "$ARQ" ] && [ -n "$SHA" ] && [ -n "$URL" ] || { echo "latest.json incompleto" >&2; exit 1; }
DEST="$BASE/versions/$VERSAO"
SERIAL_ARQ="$BASE/release-cert-serial"

# Confere <arquivo>.sig contra o pacote: raiz -> certificado -> release, tamanho e sha256.
# Mesmo formato e mesmos bytes de forge/security/release_sig.py. Imprime o serial do certificado.
verificar() {
  sig="$1"; pac="$2"
  v() { sed -n "s/^$1 //p" "$sig" | head -1; }
  [ "$(head -1 "$sig")" = "gines-forge-sig/v1" ] || { echo "assinatura em formato desconhecido" >&2; return 1; }
  [ "$(v version)" = "$VERSAO" ] && [ "$(v file)" = "$ARQ" ] || { echo "assinatura de outra versao/arquivo" >&2; return 1; }
  [ "$(v size)" = "$(wc -c < "$pac" | tr -d ' ')" ] || { echo "tamanho difere do assinado" >&2; return 1; }
  [ "$(v sha256)" = "$(sha256sum "$pac" | cut -d' ' -f1)" ] || { echo "sha256 difere do assinado" >&2; return 1; }
  kid=$(v cert_key_id); pub=$(v cert_pub); na=$(v cert_not_after); serial=$(v cert_serial)
  case "$serial" in ''|*[!0-9]*) echo "serial invalido" >&2; return 1;; esac
  [ "$(printf %s "$pub" | base64 -d 2>/dev/null | sha256sum | cut -c1-16)" = "$kid" ] || { echo "key_id nao bate com a publica" >&2; return 1; }
  pem() { { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf %s "$1" | base64 -d; } > "$TMP/k.der" \
          && openssl pkey -pubin -inform DER -in "$TMP/k.der" -out "$TMP/k.pem" 2>/dev/null; }
  confere() { # pub_b64 sig_b64 arquivo_msg
    pem "$1" || return 1
    printf %s "$2" | base64 -d > "$TMP/s.bin" 2>/dev/null || return 1
    openssl pkeyutl -verify -pubin -inkey "$TMP/k.pem" -rawin -in "$3" -sigfile "$TMP/s.bin" >/dev/null 2>&1
  }
  printf 'gines-forge-cert/v1\n%s\n%s\n%s\n%s\n' "$kid" "$pub" "$na" "$serial" > "$TMP/cert.msg"
  ok=""
  for r in $RAIZES; do if confere "$r" "$(v cert_sig)" "$TMP/cert.msg"; then ok=1; break; fi; done
  [ -n "$ok" ] || { echo "certificado nao assinado pela raiz" >&2; return 1; }
  agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ "$(printf '%s\n%s\n' "$agora" "$na" | sort | head -1)" = "$agora" ] || { echo "certificado vencido em $na" >&2; return 1; }
  visto=$(cat "$SERIAL_ARQ" 2>/dev/null || echo 0); case "$visto" in ''|*[!0-9]*) visto=0;; esac
  [ "$serial" -ge "$visto" ] || { echo "certificado revogado (serial $serial < $visto ja visto)" >&2; return 1; }
  printf 'gines-forge-release/v1\n%s\n%s\n%s\n%s\n%s\n%s\n' "$(v version)" "$(v file)" "$(v sha256)" \
    "$(v size)" "$(v commit)" "$(v issued_at)" > "$TMP/rel.msg"
  confere "$pub" "$(v sig)" "$TMP/rel.msg" || { echo "assinatura da release nao confere" >&2; return 1; }
  echo "$serial"
}

if [ -x "$DEST/bin/gines-forged" ]; then
  echo ">> $VERSAO ja esta instalada em $DEST"
else
  echo ">> baixando $ARQ"
  curl -fsSL --retry 3 -o "$TMP/$ARQ" "$URL"
  SERIAL=""
  if curl -fsSL --retry 3 -o "$TMP/$ARQ.sig" "$URL.sig" 2>/dev/null; then
    SERIAL=$(verificar "$TMP/$ARQ.sig" "$TMP/$ARQ") || { echo "assinatura NAO confere: pacote recusado" >&2; exit 1; }
    echo ">> assinatura ok (certificado serial $SERIAL)"
  elif [ "${GINES_FORGE_ALLOW_UNSIGNED:-}" = "1" ]; then
    echo "!! $VERSAO NAO tem assinatura; instalando so pelo sha256 porque GINES_FORGE_ALLOW_UNSIGNED=1" >&2
    [ "$SHA" != assinado ] || { curl -fsSL --retry 3 -o "$TMP/sha256" "$URL.sha256"; SHA=$(cut -d' ' -f1 "$TMP/sha256"); }
    echo "$SHA  $TMP/$ARQ" | sha256sum -c - >/dev/null || { echo "sha256 NAO confere: pacote recusado" >&2; exit 1; }
  else
    echo "$VERSAO nao tem assinatura: recusado (versao antiga? GINES_FORGE_ALLOW_UNSIGNED=1 aceita so pelo sha256)" >&2
    exit 1
  fi
  echo ">> extraindo em $DEST"
  mkdir -p "$BASE/versions"
  rm -rf "$DEST.partial"; mkdir -p "$DEST.partial"
  tar -xzf "$TMP/$ARQ" -C "$DEST.partial" --strip-components=1
  grep -qx "$VERSAO" "$DEST.partial/VERSION" || { echo "o pacote diz outra versao" >&2; exit 1; }
  # sanidade ANTES de virar current: o daemon do pacote responde
  "$DEST.partial/bin/gines-forged" --version >/dev/null || { echo "o daemon do pacote nao roda aqui" >&2; exit 1; }
  rm -rf "$DEST"; mv "$DEST.partial" "$DEST"
  # O maior serial ja aceito (o daemon le o mesmo arquivo): certificado velho deixa de valer.
  if [ -n "$SERIAL" ] && [ "$SERIAL" -gt "$(cat "$SERIAL_ARQ" 2>/dev/null || echo 0)" ]; then
    echo "$SERIAL" > "$SERIAL_ARQ.tmp" && mv -f "$SERIAL_ARQ.tmp" "$SERIAL_ARQ"
  fi
fi

echo ">> current -> versions/$VERSAO"
[ -L "$BASE/current" ] && cp -P "$BASE/current" "$BASE/previous" 2>/dev/null || true
ln -sfn "versions/$VERSAO" "$BASE/current.tmp" && mv -T "$BASE/current.tmp" "$BASE/current"
mkdir -p "$BIN"
# Scripts, nao symlinks: o wrapper do pacote resolve o proprio diretorio por $0, e um
# symlink em ~/.local/bin o faria procurar o Python la (achado do teste ponta a ponta).
for w in gines-forged forge-cli; do
  printf '#!/bin/sh\nexec "%s/current/bin/%s" "$@"\n' "$BASE" "$w" > "$BIN/$w.tmp" && chmod 755 "$BIN/$w.tmp" && mv -f "$BIN/$w.tmp" "$BIN/$w"
done

echo ">> servico de usuario"
mkdir -p "$UNIT_DIR"
if [ -f "$DEST/share/gines-forged.service" ]; then
  # A unit vem no pacote (a do repositorio, com ExecStart/PATH da instalacao por usuario).
  install -m644 "$DEST/share/gines-forged.service" "$UNIT_DIR/gines-forged.service"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  if systemctl --user is-active --quiet gines-forged; then
    systemctl --user restart gines-forged
  else
    systemctl --user enable --now gines-forged || true
  fi
  loginctl enable-linger "$USER" 2>/dev/null || true
  sleep 1; systemctl --user --no-pager status gines-forged | head -5 || true
fi
if [ -x /usr/bin/gines-forged ] && dpkg-query -W gines-forge >/dev/null 2>&1; then
  cat <<'FIM'

  Havia um gines-forge instalado pelo .deb. A instalacao por usuario passa a valer
  (~/.local/bin vem antes no PATH e a unit de usuario sobrepoe a de /usr/lib). Quando
  quiser, remova o pacote antigo:  sudo apt remove gines-forge
FIM
fi
echo ">> pronto: gines-forge $VERSAO em $BASE/current"
