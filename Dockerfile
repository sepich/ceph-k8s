# Used in osd-discover
FROM debian:stretch-slim
ADD https://storage.googleapis.com/kubernetes-release/release/v1.16.0/bin/linux/amd64/kubectl /bin/kubectl
RUN apt-get update && apt-get install -y gettext-base lvm2 && chmod +x /bin/kubectl && rm -r /var/lib/apt/lists/*

