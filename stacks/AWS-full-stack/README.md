# OpenEMR Cloud FS

A production grade solution for facilities and hospitals to run their OpenEMR v5 installation in the Amazon cloud.

Many OpenEMR users run their system on premise and have not yet realized the benefits of cloud technologies. This repository provides a HIPAA and [BAA](http://searchhealthit.techtarget.com/definition/HIPAA-business-associate-agreement-BAA)-friendly solution for deploying OpenEMR securely and reliably to the cloud.

a. For AWS customers that are HIPAA covered entities, before deployment of OpenEMR Cloud FS, you must navigate to the "Artifacts" section of the AWS console, find the AWS non-disclosure agreement (NDA), read it and accept it, then find the AWS Business Associate amendment (BAA), read it and accept it.
 
b. For AWS customers that are HIPAA covered entities, OpenEMR Cloud FS must be deployed in the U.S. East (N. Virginia) Region (preferred) or U.S. West (Oregon) Region.

## 📒 Setup Guide

While this setup is mostly automated, you are asked to fill in certain details that are unique to your practice. Walk through each chapter below to set up your cloud.

1. 🚴 [Getting Started](chapters/01-Getting-Started.md)
2. 🖥 [Application Servers](chapters/02-Application-Servers.md)
3. ▶ [Secure Domain Setup](chapters/03-Secure-Domain-Setup.md)
4. 📝 [VPN Access](chapters/04-VPN-Access.md)
5. 🎛 [Administration](chapters/05-Administration.md)
6. ☁ [Stack Operations](chapters/06-Stack-Operations.md)

## License

MIT
