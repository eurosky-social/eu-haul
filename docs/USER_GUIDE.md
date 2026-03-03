# How to Move Your Bluesky Account with eu-haul

eu-haul helps you move your Bluesky account from one server to another. Think of it like moving to a new apartment -- all your posts, photos, followers, and settings come with you. Your identity stays the same; only where your data lives changes.

## Before You Start

Make sure you have:

- **Your Bluesky handle** (e.g. `yourname.bsky.social`)
- **Your Bluesky password** (the one you log in with -- not an App Password)
- **Access to your email** -- the one linked to your Bluesky account (you'll receive verification codes)
- **The address of the server you're moving to** (e.g. `https://pds.example.com`) -- the server operator should have given you this
- **An invite code** for the new server, if one is required (ask the server operator)

> **Good to know:** Moving your account does not change your username, your followers, or who you follow. Everything transfers automatically.

## Step-by-Step Guide

### Step 1: Log In With Your Current Account

1. Open the eu-haul website in your browser.
2. Enter your **current Bluesky handle** (e.g. `yourname.bsky.social`).
3. Enter your **password**.
4. If you have two-factor authentication (2FA) enabled, you'll be asked for that code too.
5. Click **Next**.

eu-haul will verify your credentials and look up your account. Your password is only used to create a temporary login session -- it is encrypted and never stored in plain text.

### Step 2: Confirm Your Email

1. Enter the **email address** linked to your Bluesky account.
   - This may already be filled in for you.
2. Click **Next**.

You'll use this email later to receive important verification codes.

### Step 3: Choose Your New Server

1. Pick the server you're moving to from the list, **or** select "Other" and type in the server address.
2. If the server requires an **invite code**, you'll be asked to enter it here.
3. Click **Next**.

eu-haul checks that the server is reachable and ready to accept your account.

### Step 4: Choose Your New Handle

Here you decide what your username will look like on the new server.

- **Server-hosted handle**: The new server gives you a handle based on its domain (e.g. `yourname.newserver.social`).
- **Custom domain**: If you own a domain name, you can use it as your handle (e.g. `yourname.com`). This requires a DNS record -- follow the instructions on screen.
- **Keep your current handle**: In some cases you can keep your existing handle. If this option is available, it will be shown.

Pick the option that works best for you and click **Next**.

### Step 5: Review and Confirm

1. Review all the information you've entered.
2. Read and accept the terms.
3. Click **Start Migration**.

After submitting, you'll be taken to your **migration status page**. Bookmark this page -- it's the only way to check on your migration.

You'll also receive an **email verification code**. Enter this code on the status page to confirm your identity before the migration begins.

## What Happens During the Migration

Once you've verified your email, the migration starts automatically. You'll see a progress bar that updates every few seconds. Here's what's happening behind the scenes:

| Stage | What's happening |
| --- | --- |
| Creating account | Setting up your new home on the target server |
| Importing posts | Copying all your posts, likes, follows, blocks, and lists |
| Transferring media | Moving your photos, videos, and profile picture |
| Importing preferences | Copying your Bluesky app settings (muted words, saved feeds, etc.) |

**This can take a while.** If you have lots of photos and videos, the media transfer step may take several minutes or even longer. You don't need to keep the page open -- you can come back to your status page any time using the link you bookmarked.

## The PLC Token Step (Important!)

After all your data has been transferred, the migration will pause and ask you for a **PLC token**. This is a confirmation code that authorizes the final step of your move.

1. **Check your email** for a message with the subject line about confirming your PLC operation.
2. Copy the **token** from the email.
3. Paste it into the field on your migration status page.
4. Read the warning carefully.

> **This is the point of no return.** Once you submit the PLC token, your account officially moves to the new server. This step updates a global directory that tells the network where your account lives. It cannot be easily undone.

5. Click **Submit** to finalize the move.

**Didn't get the email?** Check your spam folder. If it's not there, click "Request new PLC token" on the status page to have it sent again.

## After the Migration

Once the migration is complete, you'll see a success message. A few important things:

### Save Your Recovery Key

After the migration completes, you may be shown a **recovery key** (also called a rotation key). This is like a master key for your account identity.

- **Copy it and store it somewhere safe** (password manager, printed copy, etc.).
- This key lets you regain control of your account identity if something ever goes wrong.
- You won't be able to retrieve it later -- save it now.

### Log In to Your New Server

- Open your Bluesky app (or the website).
- Log in with your **new handle** and the password you use for the new server.
- Everything should be there: your posts, your followers, your settings.

### Clean Up

- Your old account will be **automatically deactivated**. You don't need to do anything.
- The migration status page will show a **Delete Migration Record** button. Click this when you're ready to remove all migration data from the eu-haul server.
- Migration records are automatically deleted after a set period for your privacy.

## FAQ

**Will I lose my followers?**
No. Because your identity (your DID) stays the same, all your followers automatically follow you at your new location. They don't need to do anything.

**Will my posts disappear?**
No. All your posts, likes, reposts, follows, blocks, and lists are copied to the new server.

**Can I still use the Bluesky app?**
Yes. Bluesky works with any AT Protocol server. Just log in with your new handle and password.

**What if something goes wrong during the migration?**
If the migration fails before the PLC token step, you can safely retry. Your original account is untouched until the very last step. The status page will show what went wrong and suggest what to do.

**Can I move back to my old server?**
Moving back requires another migration. If you saved your rotation key, you can use it to regain control of your identity in an emergency.

**How long does a migration take?**
It depends on how much data you have. A typical account takes a few minutes. Accounts with thousands of photos or videos may take longer.

**Do I need to keep the browser open?**
No. The migration runs on the server. You can close your browser and come back to the status page later.

**Is my password safe?**
Your password is used once to create a temporary login session, then encrypted. It is never stored in plain text, and all credentials are automatically deleted after the migration completes.
