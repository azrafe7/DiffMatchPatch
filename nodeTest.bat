@echo off
echo Compile
call haxe test.hxml -js bin\testall.js -lib hxnodejs
echo.
pause
echo Run
call devtool bin\testall.js --break
