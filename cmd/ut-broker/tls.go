package main

// (Self-signed TLS was removed: macOS ATS rejects self-signed certs for remote
// hosts. The cluster broker now serves a real *.ts.net cert via tsnet — see
// listener() in main.go. Local stays plain http/ws over the loopback, which ATS
// exempts.)
