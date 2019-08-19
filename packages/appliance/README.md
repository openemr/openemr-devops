# OpenEMR 5.0.2 Appliance

A self-contained, pre-configured OpenEMR virtual appliance, compatible with VirtualBox and VMWare.

## Requirements

* 64-bit VirtualBox or VMWare
* 100 GB drive space
* 2 gigabytes of RAM to allocate

## Installation

This example focuses on installing the OpenEMR appliance on a 64-bit Windows 7 or 10 desktop via VirtualBox.

1. Download and install [VirtualBox](https://www.virtualbox.org/wiki/Downloads).
2. Download the [OpenEMR Appliance](https://downloads.sourceforge.net/openemr/OpenEMR-Appliance-5-0-2-1.ova) OVA.
   * Current release: 2018-06-09
   * MD5: 135ba3ae96edf8ffec938823a5f28d35
   * SHA-1: 057f69a0e31e6655bb9814c64421a3f0cffc4363
3. Start VirtualBox, and select **Import Appliance** from the **File** menu.
4. Select the download OVA and select **Next**.
5. You should be installing the `OpenEMR Appliance`! Select **Import**.
6. Unpacking the instance and preparing it for use could take a while. While you're waiting, why not skim over the rest of the guide?

## Operation

1. Right-click the image and select **Start...**, then **Headless Start**.
2. In a minute or two, OpenEMR will spin up and be ready for use!
3. Connect to OpenEMR from localhost:80, and log in with user `admin`, password `pass`. Note that any computer on your network can also connect to OpenEMR on your IP.

## Administration

The OpenEMR appliance is a Ubuntu 16.04 instance built around the [OpenEMR Docker](https://hub.docker.com/r/openemr/openemr/) and a MySQL 5.7 container equipped with Duplicity and Percona XtraBackup. You may ssh or scp to the instance on localhost:22 (see below for credentials), and you can consult the notes on our [cloud solution](../lightsail/README.md) for more about the automated backups and how to interact with service containers.

### Credentials

* ssh: `openemr` / `openemr`
* MySQL: `root` / `root`
* OpenEMR: `admin` / `pass`

### Share Volumes With Host

Once you install the guest additions appropriate for your platform, you can directly share files from the guest to the host via the Windows File Explorer. If you don't wish to install these packages, you can use scp (via WinSCP or another client) to copy files between guest and host.

VirtualBox example: `sudo apt-get install virtualbox-guest-dkms`

### Launch on Host Boot

The [VBoxManage](https://www.virtualbox.org/manual/ch08.html#vboxmanage-autostart) service can start your hosted appliance as soon as the system boots up.

### Upgrade to OpenEMR Cloud Express

OpenEMR Cloud Express, available from the Amazon Marketplace, uses the same backup and recovery regimen your appliance does. Therefore, putting your backups on an Express server (or a do-it-yourself Amazon Lightsail instance) and initiating a restore will have you running in Amazon's datacenter in under an hour, depending on the size of your practice.

## Troubleshooting

### "I can't connect to (ssh/webserver)"

If another virtualized host or system service is holding on to port 22 or 80, VirtualBox won't be able to hook the guest machine to the hosts's network on those ports. You may be running another virtual system somewhere, or perhaps you've installed WampServer or XAMPP and the embedded Apache is running.

You can disable or uninstall these services, or if you prefer, under **Settings**, **Network**, **Network 1**, **Advanced**, **Port Forwarding** (VirtualBox) you can find the connections forwarding traffic from host to guest. Reconnecting the host's 8888 to the guest's 80 will allow you to connect to OpenEMR if a rogue service on port 80 is the source of the problem.

While you've got this panel open, though, note the host binding on port 22, the ssh port. This allows us to say that only connections from 127.0.0.1 &mdash; the host itself &mdash; should be allowed to connect to the guest. This is acceptable, but you might also delete this rule as a general security measure and briefly put it back whenever you need secure shell access to the guest.
