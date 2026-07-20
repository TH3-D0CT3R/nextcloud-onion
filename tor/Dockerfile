FROM alpine:3.22

RUN apk add --no-cache tor

COPY torrc /etc/tor/torrc

RUN mkdir -p /var/lib/tor && chown -R tor:tor /var/lib/tor && chmod 700 /var/lib/tor

USER tor

CMD ["tor", "-f", "/etc/tor/torrc"]
