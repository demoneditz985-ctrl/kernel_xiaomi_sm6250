# ShadowTweaks

Companion runtime-tweaks module for **Shadow Kernel** (Vortex FR), for
Xiaomi **miatoll** (POCO M2 Pro / Redmi Note 9 Pro / 9S / ...).

It applies safe, conservative `sysctl` values that complement the kernel-side
tuning already baked into Shadow Kernel, giving the best balance of:

- **Gaming** – BBR networking, fairer scheduler wakeup/interactivity.
- **Daily use** – smooth memory behaviour with zRAM (`vm.swappiness=100`).
- **Battery backup** – reduced logging noise and sane dirty-page writeback.

## Install

Flash `ShadowTweaks` with **KernelSU** (recommended) or **Magisk**:
1. Open the KernelSU / Magisk app.
2. Install the module (zip this folder or the prebuilt module zip).
3. Reboot.

You can also drop `system/etc/sysctl.d/99-shadow.conf` directly into your
ROM if you prefer not to use a module.

## Tweakable knobs

See `system/etc/sysctl.d/99-shadow.conf` for the full list and
`service.sh` for what is applied at boot. All values are safe to edit.
