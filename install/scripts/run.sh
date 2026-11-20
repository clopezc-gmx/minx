#!/usr/bin/env bash
# set -x

if [[ 1 == 1 ]]; then
	./download_repos.sh
fi

if [[ 0 == 1 ]]; then
	./00_root_init.sh
fi

if [[ 0 == 1 ]]; then
	./01_root_install_packages.sh --run-update
	./01_root_install_packages.sh --initial-setup
	./01_root_install_packages.sh --install-firmware
	./01_root_install_packages.sh --install-base
	./01_root_install_packages.sh --install-dev
	./01_root_install_packages.sh --install-desktop
	./01_root_install_packages.sh --install-radio
	./01_root_install_packages.sh --install-power
	./01_root_install_packages.sh --install-latex
fi

if [[ 1 == 1 ]]; then
	./02_user_build_sucklesstools.sh --all
fi

if [[ 0 == 1 ]]; then
	./03_root_install_suckless.sh --all
fi

if [[ 0 == 1 ]]; then
	./04_root_install_external.sh --go
	#./04_root_install_external.sh --qemu
	./04_root_install_external.sh --jetbrains-mono
	./04_root_install_external.sh --spotify
	./04_root_install_external.sh --librewolf
	./04_root_install_external.sh --onlyoffice
	./04_root_install_external.sh --qutebrowser
fi

if [[ 0 == 1 ]]; then
	./05_user_install_external.sh --all
fi

if [[ 0 == 1 ]]; then
	./06_user_build_external.sh --all
fi

if [[ 0 == 1 ]]; then
	./07_root_install_user_builds.sh --all
fi

if [[ 0 == 1 ]]; then
	./08_user_setup.sh --laptop --clone-personal-repos
	./08_user_setup.sh --laptop --restore-rc-files
	./08_user_setup.sh --laptop --install-tt laptop
	./08_user_setup.sh --laptop --install-wikiviewer
	./08_user_setup.sh --laptop --install-mime-types
	./08_user_setup.sh --laptop --init-mail
	./08_user_setup.sh --laptop --install-services
	./08_user_setup.sh --laptop --get-vim-vundle
fi
