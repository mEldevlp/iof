# Тестовый стенд iof: «сервер» Ubuntu 24.04 с systemd и SSH, как только что арендованный у хостера.
# Собирается и запускается через stand/stand.sh. git, python3 и qrencode специально не ставятся:
# на управляющий сервер их ставит stand.sh setup, на новый — iof migrate start
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       systemd systemd-sysv dbus openssh-server sudo cron iproute2 iptables curl ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*

# Вход root по паролю stand, как на новом сервере. machine-id у всех контейнеров получается
# одинаковым, как у VPS из одного образа: iof не должен на него полагаться
RUN echo 'root:stand' | chpasswd \
    && sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/; s/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && systemctl enable ssh.service cron.service \
    && systemctl disable ssh.socket \
    && systemctl mask systemd-logind.service getty.target console-getty.service \
    && : > /etc/machine-id

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
