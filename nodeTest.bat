@echo off
echo Compiling...
call haxe test.hxml -js bin\testall.js -lib hxnodejs
if '%ERRORLEVEL%'=='0' goto next
goto :eof

:next
echo DONE
echo Press a key to debug with node devtool...
pause > NUL
echo Launching...
call devtool bin\testall.js --break
echo DONE