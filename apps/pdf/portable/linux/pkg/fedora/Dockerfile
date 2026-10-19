# Fedora build toolchain for the shenzhenpdf RPM.
# Built/used by portable/linux/pkg/build-rpm.sh:
#   docker build -t shenzhen-build-fedora portable/linux/pkg/fedora
FROM fedora:42
RUN dnf install -y --setopt=install_weak_deps=False \
    gcc gcc-c++ make pkgconfig git \
    gtk4-devel libadwaita-devel openssl-devel \
    rpm-build rpmdevtools \
    python3 file \
    && dnf clean all
