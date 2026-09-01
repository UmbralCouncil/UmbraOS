{ lib, pkgs, ... }:
{
  system.stateVersion = "26.05";
  networking.hostName = "umbra-core-lab";
  networking.useDHCP = false;
  networking.firewall.enable = true;

  boot.consoleLogLevel = 0;
  boot.kernelParams = [
    "quiet"
    "udev.log_level=3"
    "systemd.show_status=false"
    "rd.systemd.show_status=false"
  ];

  services.getty.autologinUser = "root";
  users.users.root = {
    password = "";
    home = lib.mkForce "/home/operator";
    createHome = true;
  };

  environment.systemPackages = with pkgs; [
    bashInteractive
    busybox
    coreutils
    findutils
    gnugrep
    gnused
    gawk
  ];

  systemd.services.umbra-core-lab-profile = {
    description = "Seed the Umbra Core training guest";
    wantedBy = [ "multi-user.target" ];
    before = [ "getty@tty1.service" "serial-getty@ttyS0.service" ];
    after = [ "home-operator.mount" ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 -o root -g root /home/operator
      install -d -m 0755 /opt/umbra/source /opt/umbra/config/nested /opt/umbra/data /var/log
      cat > /home/operator/.profile <<'PROFILE'
      export PATH=/run/current-system/sw/bin
      export PS1='root@umbra-lab:\w# '
      PROFILE
      cat > /opt/umbra/source/briefing.txt <<'EOF'
      Operation Nightfall training briefing
      Verify the evidence and report your findings.
      EOF
      printf '%s\n' 'Umbra training evidence: nightfall' > /opt/umbra/source/evidence.txt
      printf '%s\n' 'status=pending' > /opt/umbra/source/status.conf
      printf '%s\n' 'mode=training' > /opt/umbra/config/base.conf
      printf '%s\n' 'audit=true' > /opt/umbra/config/audit.conf
      printf '%s\n' 'scope=local' > /opt/umbra/config/nested/network.conf
      cat > /opt/umbra/data/users.csv <<'EOF'
      username,role,shell
      ada,analyst,/bin/bash
      grace,operator,/bin/ash
      linus,reviewer,/bin/sh
      EOF
      printf '%s\n' 10.0.0.8 10.0.0.3 10.0.0.8 10.0.0.21 10.0.0.3 > /opt/umbra/data/addresses.txt
      cat > /var/log/umbra.log <<'EOF'
      INFO lab initialized
      ERROR failed authentication check
      WARN retry scheduled
      ERROR integrity mismatch
      INFO lab ready
      EOF
      chown root:root /home/operator/.profile
      chmod 0600 /home/operator/.profile
      chmod -R a-w /opt/umbra
    '';
  };

  security.sudo.enable = false;

  microvm = {
    hypervisor = "qemu";
    vcpu = 2;
    mem = 1024;
    interfaces = [ ];
    shares = [ ];
    socket = "control.socket";
    volumes = [ {
      image = "operator-home.img";
      mountPoint = "/home/operator";
      size = 512;
    } ];
  };
}
