# ProxMobile

A native SwiftUI Proxmox VE client that adapts the complete management surface to iPhone.

## Native features

- Datacenter overview with aggregate CPU, memory, storage, and guest status
- Node, QEMU VM, LXC, and storage browser with search and detail views
- Cluster task history
- Confirmed start, shutdown, reboot, and stop actions
- Native management catalog generated from the connected server's exact API schema
- Typed controls, required-field validation, current-value loading, and confirmed writes
- Native create-VM and create-container entry points
- Node, guest, firewall, backup, replication, storage, access, HA, SDN, ACME, and Ceph operations
- Password/ticket or API-token authentication
- Keychain credential storage and CSRF-protected password actions

The native interface reads `/pve-docs/api-viewer/apidoc.js` from the connected Proxmox host, so its available fields and operations follow the installed server version. An authenticated official web view remains available under Settings as a compatibility fallback while specialized iPhone workflows are refined.

## Run

1. Install and open the project with a current full Xcode release.
2. Connect and unlock your iPhone, accept **Trust This Computer**, and enable Developer Mode if iOS asks.
3. Select the `ProxMobile` target, choose your Apple Development team under **Signing & Capabilities**, select your iPhone as the run destination, and press Run.
4. Sign in with either a normal Proxmox account (`root@pam`, `user@pve`, and similar) or an API token (`user@realm!name`).

Passwords and token secrets are stored in iOS Keychain. Session tickets stay in memory. The untrusted-certificate switch is intended only for testing against a known server on a trusted LAN.

## Status

Active development. The complete API is exposed through native typed forms; the next milestone is replacing every schema-backed general form with a purpose-designed iPhone workflow.
