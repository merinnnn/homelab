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

