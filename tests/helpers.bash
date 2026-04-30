setup_download_test() {
    REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
    TEST_WORKDIR="$BATS_TEST_TMPDIR/work"
    mkdir -p "$TEST_WORKDIR"
    cp "$REPO_ROOT/download.sh" "$TEST_WORKDIR/download.sh"
}

write_fake_dra() {
    local mode="${1:-success}"
    cat > "$TEST_WORKDIR/dra" <<'FAKE_DRA'
#!/usr/bin/env bash
set -euo pipefail

mode="${FAKE_DRA_MODE:-success}"
asset=""
repo=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        download)
            shift
            ;;
        --select)
            asset="$2"
            shift 2
            ;;
        *)
            repo="$1"
            shift
            ;;
    esac
done

printf '%s|%s\n' "$repo" "$asset" >> dra.calls

case "$mode:$asset" in
    fail:*)
        exit 1
        ;;
    hash-mismatch:hashes.txt)
        printf '0000000000000000000000000000000000000000000000000000000000000000  build/hysteria-linux-amd64\n' > hashes.txt
        ;;
    star-hash:hashes.txt)
        printf 'd744f9fa5d5cc4d8cee0e58ea481ad20c1c42ff2243805f1e18886bd9c406802 *build/hysteria-linux-amd64\n' > hashes.txt
        ;;
    *:hashes.txt)
        # sha256 of printf 'fake-hysteria-binary'
        printf 'd744f9fa5d5cc4d8cee0e58ea481ad20c1c42ff2243805f1e18886bd9c406802  build/hysteria-linux-amd64\n' > hashes.txt
        ;;
    *:hysteria-linux-amd64)
        printf 'fake-hysteria-binary' > hysteria-linux-amd64
        ;;
    *:caddy-linux-amd64.tar.gz)
        mkdir -p caddy-archive
        printf 'fake-caddy' > caddy-archive/caddy
        tar -czf caddy-linux-amd64.tar.gz -C caddy-archive caddy
        ;;
    *:Xray-linux-64.zip)
        printf 'fake-xray' > xray
        zip -q Xray-linux-64.zip xray
        rm -f xray
        ;;
    *)
        exit 1
        ;;
esac
FAKE_DRA
    chmod +x "$TEST_WORKDIR/dra"
    export FAKE_DRA_MODE="$mode"
}

run_download() {
    (cd "$TEST_WORKDIR" && bash ./download.sh "$@")
}

render_template() {
    local template_path="$1"
    local content
    shift
    content=$(<"$template_path")

    while [ "$#" -gt 0 ]; do
        local key="$1"
        local value="$2"
        shift 2
        content="${content//\$\{$key\}/$value}"
    done

    printf '%s\n' "$content"
}

source_install_script() {
    REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
    source "$REPO_ROOT/install.sh"
}
