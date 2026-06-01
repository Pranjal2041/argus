import Foundation

// Networking uses URLSession.shared. Local brokers are reached over loopback
// (ATS-exempt) plain http/ws; the cluster broker presents a real *.ts.net
// Tailscale cert, so the default trust evaluation succeeds — no custom handling.
