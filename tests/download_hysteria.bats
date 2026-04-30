#!/usr/bin/env bats

load helpers

setup() {
    setup_download_test
}

@test "hysteria2 downloads and verifies binary" {
    write_fake_dra success

    run run_download hysteria2 --dir "$TEST_WORKDIR/out"

    [ "$status" -eq 0 ]
    [ -x "$TEST_WORKDIR/out/hysteria" ]
    calls=$(<"$TEST_WORKDIR/dra.calls")
    [[ "$calls" == *"apernet/hysteria|hysteria-linux-amd64"* ]]
    [[ "$calls" == *"apernet/hysteria|hashes.txt"* ]]
}

@test "hysteria2 accepts sha256sum binary marker path" {
    write_fake_dra star-hash

    run run_download hysteria2 --dir "$TEST_WORKDIR/out"

    [ "$status" -eq 0 ]
    [ -x "$TEST_WORKDIR/out/hysteria" ]
}

@test "hysteria2 dra failure fails closed" {
    write_fake_dra fail

    run run_download hysteria2 --dir "$TEST_WORKDIR/out"

    [ "$status" -ne 0 ]
    [ ! -f "$TEST_WORKDIR/out/hysteria" ]
    [ ! -f "$TEST_WORKDIR/hysteria-linux-amd64" ]
}

@test "hysteria2 hash mismatch fails closed and keeps old binary" {
    mkdir -p "$TEST_WORKDIR/out"
    printf 'old-binary' > "$TEST_WORKDIR/out/hysteria"
    write_fake_dra hash-mismatch

    run run_download hysteria2 --force --dir "$TEST_WORKDIR/out"

    [ "$status" -ne 0 ]
    [ "$(<"$TEST_WORKDIR/out/hysteria")" = "old-binary" ]
    [ ! -f "$TEST_WORKDIR/hysteria-linux-amd64" ]
}

@test "all downloads caddy xray and hysteria2" {
    write_fake_dra success

    run run_download all

    [ "$status" -eq 0 ]
    [ -x "$TEST_WORKDIR/app/caddy/caddy" ]
    [ -x "$TEST_WORKDIR/app/xray/xray" ]
    [ -x "$TEST_WORKDIR/app/hysteria/hysteria" ]
}

@test "xraycaddy downloads only caddy and xray" {
    write_fake_dra success

    run run_download xraycaddy

    [ "$status" -eq 0 ]
    [ -x "$TEST_WORKDIR/app/caddy/caddy" ]
    [ -x "$TEST_WORKDIR/app/xray/xray" ]
    [ ! -e "$TEST_WORKDIR/app/hysteria/hysteria" ]
}

@test "default component keeps xraycaddy compatibility" {
    write_fake_dra success

    run run_download

    [ "$status" -eq 0 ]
    [ -x "$TEST_WORKDIR/app/caddy/caddy" ]
    [ -x "$TEST_WORKDIR/app/xray/xray" ]
    [ ! -e "$TEST_WORKDIR/app/hysteria/hysteria" ]
}
