#!/usr/bin/env bash
# set -x

option=1

case $option in
1)
	./00_root_init.sh
	./01_root_install_packages.sh --run-update
	./01_root_install_packages.sh --initial-setup
	./01_root_install_packages.sh --install-firmware
	./01_root_install_packages.sh --install-base
	./01_root_install_packages.sh --install-dev
	./01_root_install_packages.sh --install-desktop
	./01_root_install_packages.sh --install-radio
	./01_root_install_packages.sh --install-power
	./01_root_install_packages.sh --install-latex
	;;

2)
	./01_user_download_repos.sh

	./02_user_build_sucklesstools.sh --dwm
	./02_user_build_sucklesstools.sh --st
	./02_user_build_sucklesstools.sh --sent
	./02_user_build_sucklesstools.sh --slock
	;;

3)
	./03_root_install_suckless.sh --dwm
	./03_root_install_suckless.sh --st
	./03_root_install_suckless.sh --sent
	./03_root_install_suckless.sh --slock

	./04_root_install_external.sh --go
	./04_root_install_external.sh --qemu
	./04_root_install_external.sh --jetbrains-mono
	./04_root_install_external.sh --spotify
	./04_root_install_external.sh --librewolf
	./04_root_install_external.sh --onlyoffice
	./04_root_install_external.sh --qutebrowser
	;;

4)
	./05_user_install_external.sh --rust-and-cargo
	./05_user_install_external.sh --nvm-and-nodejs
	./05_user_install_external.sh --pipx-packages
	./05_user_install_external.sh --go-packages
	./05_user_install_external.sh --nodejs-packages
	./05_user_install_external.sh --invariant-repos
	./05_user_install_external.sh --calix

	./06_user_build_external.sh --ctags
	./06_user_build_external.sh --vim
	./06_user_build_external.sh --taskwarrior
	./06_user_build_external.sh --timewarrior
	./06_user_build_external.sh --pdfjs
	./06_user_build_external.sh --qutebrowser
	;;

5)
	./07_root_install_user_builds.sh --ctags
	./07_root_install_user_builds.sh --vim
	./07_root_install_user_builds.sh --taskwarrior
	./07_root_install_user_builds.sh --timewarrior
	./07_root_install_user_builds.sh --pdfjs
	./07_root_install_user_builds.sh --qutebrowser
	;;

6)
	./08_user_setup.sh --clone-personal-repos
	./08_user_setup.sh --restore-rc-files
	./08_user_setup.sh --install-tt laptop
	./08_user_setup.sh --install-wikiviewer
	./08_user_setup.sh --install-mime-types
	./08_user_setup.sh --init-mail
	./08_user_setup.sh --install-services
	./08_user_setup.sh --get-vim-vundle

	./09_inspect_user_services.sh >inspect_user_services.txt
	;;

7)
	./10_root_setup.sh --restore-rc-files
	./10_root_setup.sh --install-services

	./11_inspect_shutdown_services.sh >inspect_shutdown_services.txt
	;;
esac
