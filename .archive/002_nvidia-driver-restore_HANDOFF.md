# Handoff: Restore NVIDIA driver on DGX Spark after `apt upgrade`

**Generated**: 2026-05-23
**Branch**: main
**Status**: Diagnosis confirmed and documented — awaiting host-side `sudo` commands to apply the fix

## Goal

Get `nvidia-smi` working again on the DGX Spark, then re-enable GPU access for
`docker-llm-switch` (ComfyUI, FLUX, all llama slots). Root cause: the kernel
ABI was bumped to `6.17.0-1018-nvidia` but the matching
`linux-modules-nvidia-580-open-6.17.0-1018-nvidia` package was never
installed, so the NVIDIA module cannot load. Full diagnosis with NVIDIA
forum citations: [gremlins/01_NVIDIA-DRIVER-ABI-MISMATCH.md](gremlins/01_NVIDIA-DRIVER-ABI-MISMATCH.md).

## Steps

### 1. Restore the driver

```bash
sudo apt update
sudo apt install linux-modules-nvidia-580-open-$(uname -r)
sudo modprobe nvidia
nvidia-smi
```

**Expected**: `nvidia-smi` prints the GB10 GPU table (driver 580.x, CUDA 13.x).

**If `modprobe nvidia` errors**: `sudo reboot`, then re-run `nvidia-smi` after login.

### 2. Verify Docker GPU access

```bash
docker-llm-switch comfyui
```

**Expected**: ComfyUI starts on `:8188` without `nvml error: driver not loaded`.

### 3. Prevent recurrence (one-time)

```bash
sudo apt install linux-modules-nvidia-580-open-nvidia-hwe-24.04 nvidia-driver-pinning-580
```

After this, future `apt upgrade` runs will keep the kernel and the matching
NVIDIA module package in lockstep.

### 4. Pre-upgrade discipline (every future `apt upgrade`)

Before rebooting after any `apt upgrade` that touches the kernel:

```bash
apt list --upgradable 2>/dev/null | grep -E 'linux-image|linux-modules-nvidia'
```

If a new `linux-image-*-nvidia` appears **without** a matching
`linux-modules-nvidia-580-open-*-nvidia`, stop and investigate before reboot.

## Don't do this

- Don't `apt purge nvidia-*` to "start clean" — the DGX Spark recovery image
  is the supported reinstall path; ad-hoc purges have bricked other users.
- Don't install the upstream `.run` driver — the DGX Spark stack expects the
  Ubuntu-packaged 580-open driver.
- Don't `apt-mark hold` the kernel to dodge the problem; install the HWE
  metapackage in step 3 instead.

## References

- Full incident report (diagnosis, why we're confident, NVIDIA forum citations):
  [gremlins/01_NVIDIA-DRIVER-ABI-MISMATCH.md](gremlins/01_NVIDIA-DRIVER-ABI-MISMATCH.md)
- Original handoff that led to this fix (archived):
  [.archive/000_nvidia-drivers_HANDOFF.md](.archive/000_nvidia-drivers_HANDOFF.md)
