# [Apogee BK-01](https://ru.wikipedia.org/wiki/%D0%90%D0%BF%D0%BE%D0%B3%D0%B5%D0%B9_%D0%91%D0%9A-01) for [MIST Board](https://github.com/mist-devel/mist-board/wiki)

A [Radio-86RK](https://ru.wikipedia.org/wiki/%D0%A0%D0%B0%D0%B4%D0%B8%D0%BE_86%D0%A0%D0%9A) clone based on [Bashkiria 2M project](http://bashkiria-2m.narod.ru/index/fpga/0-12) with addition of precise K580VM80A (i8080) Verilog model by Vslav

### Features:
- Fully functional Apogee BK-01 and Radio-86RK.
- Color/Monochrome modes
- EXTROM Support with all apps ever released for Apogee computer
- Support for RKA, RKR, GAM files

### Installation:
Copy the *.rbf file at the root of the SD card. You can rename the file to core.rbf if you want the MiST to load it automatically at startup.

Copy [apogee.rom](https://github.com/sorgelig/Apogee_MIST/tree/master/extra) to root of SD card if you wish to have EXTROM with Apogee apps.

For PAL mode (RGBS output) you need to put [mist.ini](https://github.com/sorgelig/ZX_Spectrum-128K_MIST/tree/master/releases/mist.ini) file to the root of SD card. Set the option **scandoubler_disable** for desired video output.

##### Keyboard map:

- F12 - OSD menu.
- CTRL-F11 - Reset to Apogee BK-01.
- ALT-F11 - Reset to Radio-86RK
- SHIFT-F11 - Reset to Apogee BK-01 and start EXTROM menu.
- ALT - Rus/Lat
- ESC - AP2

### Download precompiled binaries:
Go to [releases](https://github.com/sorgelig/Apogee_MIST/tree/master/releases) folder.
