# Remote Hosting

Prices and product availability below were checked on 2026-08-13. Cloud credits have account-specific expiry and service exclusions, so the billing console remains the source of truth for whether a particular SKU consumes a credit balance.

## Recommended allocation

1. **Use standard GitHub Actions for Feather's macOS CI.** The public repository can use standard hosted runners without billed minutes, and GitHub currently maps `macos-15` to an arm64 M1 runner with 3 CPU cores and 7 GB RAM. Feather's workflow therefore runs its actual arm64 tests and release build on every pull request and `main` push without using AWS or Azure credits. Larger M2 Pro runners cost $0.102 per minute and are unnecessary for the current suite. See GitHub's [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [public-repository billing policy](https://docs.github.com/en/actions/concepts/billing-and-usage), and [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing).
2. **Use AWS for the first persistent Linux agent host if the credits apply.** A 4 GB Lightsail Linux bundle is currently $24 per month with public IPv4; 8 GB is $44 per month. The bundle includes disk and transfer, which makes the first deployment simpler than assembling EC2, EBS, and networking. The 4 GB plan has a 20% per-vCPU sustained baseline, so move to 8 GB or an EC2 general-purpose instance if long compiles repeatedly exhaust burst capacity. See the official [Lightsail bundle table](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html) and [CPU baseline table](https://docs.aws.amazon.com/lightsail/latest/userguide/baseline-cpu-performance.html).
3. **Keep Azure as an independent second target or short-lived compatibility environment.** Azure offers Linux and Windows VMs, including Ampere Altra and Cobalt arm64 D-series machines, but not first-party macOS VMs. Use a small x64 Linux VM when agent-package compatibility matters more than ARM efficiency, or a Dps/Dpl ARM VM after verifying both CLIs. Deallocate test machines when idle; a stopped/deallocated VM preserves disk but cannot preserve a running tmux process. Azure's VM price is region- and disk-dependent, so use the [official calculator](https://azure.microsoft.com/pricing/calculator/) rather than recording a stale global number. See Microsoft's [VM overview](https://learn.microsoft.com/en-us/azure/virtual-machines/overview) and [ARM D-family specifications](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/d-family).
4. **Do not spend cloud credits on routine Mac CI.** EC2 Mac is a bare-metal Dedicated Host with a 24-hour minimum allocation, even for a short build. It is useful only for controlled signing, device-specific testing, or a private CI workload that GitHub's standard runner cannot handle. See the [EC2 Mac FAQ](https://aws.amazon.com/ec2/instance-types/mac/faqs/).

At $24 per month, one 4 GB host is $288 per year; the 8 GB option is $528 per year. If the credits expire after twelve months, those consume only 2.9% or 5.3% of a nominal $10,000 AWS balance. Credit expiry will therefore matter long before face-value capacity. Do not add a second persistent cloud or a cloud control plane merely to consume credits. Cloud credits pay for infrastructure, not Claude or OpenAI subscriptions/API usage.

## Cash-price alternatives

If the credits expire or exclude the desired compute, compare the operational cost as well as the VM price:

- Hetzner's post-June-2026 CAX11 ARM plan is listed at $6.99 per month before IPv4 and tax. It is the cheapest straightforward paid host here, but requires validating ARM support and accepting a provider outside the existing credit balances. [Hetzner 2026 price table](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- DigitalOcean lists 2 GB at $12 per month and 4 GB at $24 per month with per-second billing. It is simple but not cheaper than using valid AWS/Azure credits. [DigitalOcean Droplet pricing](https://www.digitalocean.com/pricing/droplets)
- Oracle advertises an Always Free Ampere allocation equivalent to 2 OCPUs and 12 GB RAM, but explicitly warns that free shapes can be unavailable in a region. Treat it as an experiment, not the only persistent handoff target. [OCI Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- If a dedicated Mac is eventually required, Scaleway lists an M1 Mac mini at €0.11 per hour or €75 per month, with a mandatory initial 24-hour lease. GitHub's free public arm64 runner is still the better default for Feather. [Scaleway Apple-silicon pricing](https://www.scaleway.com/en/pricing/apple-silicon/)

## Host setup

Feather deliberately does not provision or hold credentials. On an Ubuntu host, install the narrow runtime and create a root owned by the SSH user:

```sh
sudo apt-get update
sudo apt-get install -y git tmux
sudo install -d -o "$USER" -g "$(id -gn)" /srv/feather
```

Install and authenticate Claude Code and/or Codex on that host separately. Give the host its own repository deploy key or credential; avoid enabling `ForwardAgent` globally. Restrict inbound SSH to a trusted address or private network.

Prefer a local OpenSSH alias:

```sshconfig
Host feather-aws
    HostName example.compute.amazonaws.com
    User ubuntu
    IdentityFile ~/.ssh/feather-aws
    IdentitiesOnly yes
```

In Feather Settings, create a named profile using `feather-aws`, port `22`, and `/srv/feather`, then select **Test Connection**. Close a worktree's terminals and open files before choosing **Run Workspace Remotely…**. Feather shows a bounded preflight, transfers unpublished Git objects and verified working state without pushing, excludes ignored files and likely credentials, records token-bound ownership, and routes every later terminal for that worktree through the saved remote checkout. If SSH disconnects, the remote tmux session keeps running; use **Reconnect Remote Workspace** to attach again. Feather never recreates a missing saved session. Codex resume-by-ID works only when the corresponding session data already exists on the remote host. See the official [Codex developer commands](https://developers.openai.com/codex/cli/reference).
