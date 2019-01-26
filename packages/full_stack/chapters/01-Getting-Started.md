_[next chapter >](02-Application-Servers.md)_

# 🚴 Getting Started

### Create an AWS Account

1. Navigate to [https://aws.amazon.com/](https://aws.amazon.com/), and then click **Create an AWS Account**. If you already have an account, feel free to continue to the next section.
2. Follow along with the signup wizard.

### Select a Region

This guide uses services that are _only_ available in certain AWS regions. As of this writing, you will need to make sure you're in one the of six Amazon regions described below.

1. In the AWS Management Console, click **Services**, and then click **EC2**.
2. In the region dropdown in the top right corner, select either **N. Virginia** (least expensive), **Oregon**, **Frankfurt**, **Ireland**, or **Sydney**. Be sure to remain in this region for the remainder of this guide.

### Generate an SSH Keypair

1. In the AWS Management Console, click **Services** and then click **EC2**.
2. In the left pane, under **Network & Security**, click **Key Pairs**.
3. Click **Create Key Pair**.
4. When the **"Create Key Pair"** dialog appears, enter your username for the **Key pair name** field and click **Create**.
5. When the **Save As** dialog appears, save the .pem keyfile to a safe place. This file will be referred to in later chapters. _IMPORTANT: This will only be available once for download and is needed for future systems access._

### Launch your Cloud

1. Click the region link below that corresponds to the region you created your keypair in:
   * [N. Virginia](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-useast1/OpenEMR.json)   
   * [Oregon](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-uswest2/OpenEMR.json)
   * [Frankfurt](https://console.aws.amazon.com/cloudformation/home?region=eu-central-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-eucentral1/OpenEMR.json)
   * [Ireland](https://console.aws.amazon.com/cloudformation/home?region=eu-west-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-euwest1/OpenEMR.json)
   * [Sydney](https://console.aws.amazon.com/cloudformation/home?region=ap-southeast-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apsoutheast2/OpenEMR.json)
2. Click **Next**, and configure your stack on this page.
   * For **DocumentStorage**, enter the size of your patient documents database in gigabytes.
   * For **EC2KeyPair**, select the key pair you created in the last section.
   * For **PatientRecords**, enter the size of your patient records database in gigabytes.
   * For **RDSPassword**, enter a [strong password](https://www.random.org/passwords/?num=1&len=16&format=html&rnd=new) and note it in a safe place. Note that this is the administrator's password to the MySQL database.
   * For **TimeZone**, select the appropriate value from [this list](http://php.net/manual/en/timezones.php). Note that this value must be exact and spaces should not be entered (e.g.: **America/New_York** is valid while **America/New York** is not).

3. Click **Next**, then **Next** again.
4. Checkbox the acknowledgement at the bottom of the page.
5. Click **Create** and wait around 15-30 minutes for your OpenEMR cloud to be installed. Note that you can proceed to the next section while this install is in progress.

### Secure your Account

1. In the AWS Management Console, click **Services** and then click **IAM**.
2. In the left pane, click **Dashboard**, and store the **IAM users sign-in link** in a safe place.
3. In the left pane, click **Users**.
4. Click **Add user** to the top.
5. Under **Set user details**, enter your username in the **User name** field.
6. Under **Select AWS access type**, checkbox only **AWS Management Console access** in the **Access type** area.
7. Click **Next: Permissions**.
8. Under **Set permissions for ...**, click the **Attach existing policies directly**  box.
9. With the table at the bottom of the page in view, select **AdministratorAccess** (will be the first row).
10. Click **Next: Review**.
11. Under **Review**, ensure all information reflects the above steps.
12. Click **Next: Create user**.
13. Log out of the AWS console, go to the sign-in link you noted in step 2, and log in with your new credentials.

### Enable Multi-Factor Authentication (MFA) 

1. Sign into your root account, click on the downward facing arrow next to your username at the top right corner.Then click on My   **Security Credentials**.
2. A dialog box will appear, click on Continue to **Security Credentials**.
3. Under My Security Credentials, click on **Multi-factor Authentication(MFA)** then the **Activate MFA** button.
4. A dialogue box will appear that asks you to choose the type of MFA device to assign, choose **Virtual MFA device** and then click on the continue button.
5. A dialog box will appear asking you to setup a virtual MFA device. You can install the application which is specific to your smartphone. Use the table below as a guide. 

        Android        [Google Authenticator](https://support.google.com/accounts/answer/1066447?hl=en)  or .[Authy 2-Factor Authentication].(https://play.google.com/store/apps/details?id=com.authy.authy&amp;hl=en)
        Iphone                  .[Google authenticator].(https://itunes.apple.com/us/app/google-authenticator/id388497605?mt=8)  or  .[Authy 2-Factor authentication].(https://itunes.apple.com/us/app/authy/id494168017?mt=8)
        Windows          .[Authenticator].(https://www.microsoft.com/en-us/p/authenticator/9wzdncrfj3rj?rtc=1&activetab=pivot:overviewtab)  
6. After installing  the application on your smartphone, click on **show QR** code then use the MFA application and your smartphone camera to scan the QR code.
7. It will be registered on the MFA application in your phone and you should see six digit alternating codes.
8. Enter any two consecutive codes that will appear on your phone and click on the **Assign MFA** button.
9. A dialog box which shows that you have successfully assigned virtual MFA should appear. Click on the **close** button to return to your Security Credential page.
10. Sign out and re-sign in as a root user. After entering your email and password, click on the sign in button. You will see the multifactor authentication page, enter the **MFA code** which is currently showing in the MFA application that you installed earlier on your phone. And then click on the **submit** button to log into your AWS Management Console. 
11. Congratulations, your virtual MFA device activation is complete.





