#!/bin/sh
# Deploy minus bundler update
cd /var/www/WhyJustRun2
sudo -u whyjustrun git pull
sudo service apache2 restart
