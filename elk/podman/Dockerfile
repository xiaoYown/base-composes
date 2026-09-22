# fluent-bit 本地定制镜像: 发行版是 distroless (无 shell, 不能运行时落盘配置), 配置经 build 打进去
# (podman machine 挂载约束见 compose.yaml 头注释; 改 conf/ 后需 compose build 重建)
FROM docker.io/fluent/fluent-bit:5.0.10
COPY conf/fluent-bit.conf conf/parsers.conf conf/normalize.lua /fluent-bit/etc/
