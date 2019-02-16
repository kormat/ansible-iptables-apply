See blog post here: https://medium.com/@kormat/managing-iptables-using-ansible-v2-fc2034d5bcd9

This repo contains an ansible role + script for remotely managing iptables
using ansible. It requires ansible >= 2.6.8, and expects your iptables rules to
be located at `files/iptables/rules.v4` in the `iptables-restore` format.
