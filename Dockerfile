FROM alpine:3.22
RUN apk add --no-cache openssh-server \
    && adduser -D -s /sbin/nologin device \
    && adduser -D -s /sbin/nologin client \
    && passwd -d device && passwd -d client
COPY relay/sshd_config /etc/ssh/sshd_config
COPY relay/entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
EXPOSE 2222
ENTRYPOINT ["/entrypoint.sh"]
