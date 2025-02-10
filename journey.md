## JOURNEY

# Introduction

This file has the sole purpose to keep track of what I'm doing over time. 
I will update this page every time I work on my homelab with all the new thing I add, every time I change some configuration or even when I just play woth it.
This page will be used in future to trouble shoot and check what I have covered and whatv I didn't.

I am fully new to the homelabbing community, so I will try test out and learn as much as I can to get to a professional level.


# Session 1

I began by installing `proxmox` on an `elitedesk 800 g2 mini` and configuering all the settings. 
A first issue arised when trying to connect to the web application, even after entering the correct url, the page was unreachable.
The current set up consist of a Linksys router mesh with a node in each floor of the house. Being unable to connect the elitedesk directly to one of the nodes I purchased a very cheap WIFI extender, `tp-link AC750` and set it up to connect it to my main network. The wifi extender has an Ethernet port I can connect to, and it created it's own separate wifi.
The issue was that the tplink network was on a .1 subnet while proxmox was set up to a .100 subnet.
Not having a keyboard handy, I changed the LAN settings of the wifi extender, changing the ip address subnet and the default gateway subnet to match proxmox.
After connecting to the proxmox web app i used the shell to navigate to `/etc/network/interfaces` and modified address and gateway to point to .1 subnet.
After doing so, I reset the tp-link extender settings.

After doing that I was finally able to connect to proxmox through the web app without any issue.


# Session 2

After setting up proxmox I wanted to create a VM dedicated for `Wireguard`. I initialised on with the following specs: 
  - Debian 12.9.0
  - 1 core CPU
  - 512mb RAM
  - 10gb storage

I kept the resources extremely low since there won't be much traffic in the vpn server and I prefer saving the resources for other VMs.
First issue arised when setting up debian, for some reason `/etc/resolv.conf` didn't have `nameserver 1.1.1.1` and `nameserver 8.8.8.8`, making it impossible connecting to the dns servers. This interfered with the debian installation and also blocked me from accessing web pages afterward.

Even after modifying `/etc/resolv.conf`, it kept removing cloudflare and google dns servers for some reason. To fix that I re-added them and ran `sudo chattr +i /etc/resolv.conf` to prevent it to be overwritten (**not sure if it's the best practice, might need to look more into it**)

After finishing setting up debian, I started setting up wireguard. 
The workflow was pretty straightforward: 
  - apt update && apt upgrade -y
  - apt install wireguard -y
  - wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
  - cat /etc/wireguard/privatekey # Save it somewhere
  - cat /etc/wireguard/publickey # Save it somewhere
  - nano /etc/wireguard/wg0.conf # Type the folloing inside
      ` [Interface]
        PrivateKey = <PRIVATE_KEY>
        Address = 10.0.0.1/24
        ListenPort = 51820
        SaveConfig = true
        [Peer]
        PublicKey = <CLIENT_PUBLIC_KEY>
        AllowedIPs = 10.0.0.2/32
        `

This part worked smoothly, but going to the next command, sysctl was not installed and I had to configure it. I installed sysctl by installing procps but for some reason `/usr/sbin` was not included to PATH, making it impossible to locate the package. To fix it and continue with wireguard installation I ran:
  - apt install procps -y
  - echo 'export PATH=$PATH:/usr/sbin' >> ~/.bashrc
  - source ~/.bashrc # To add /usr/sbin to PATH
  - sysctl --version
  - sysctl net.ipv4.ip_forward
  - nano /etc/sysctl.conf # Type the following inside
         `net.ipv4.ip_forward=1`
  - sysctl -p

