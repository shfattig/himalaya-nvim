# Shared helpers for NixOS VM integration tests.
#
# Provides: user credentials, himalaya config, email corpus,
# corpus injection script, and the shared VM node configuration.
{
  pkgs,
  himalaya-cli,
}:

let
  user = "alice";
  password = "foobar";

  himalayaConfig =
    pkgs.writeText "himalaya.toml" # toml
      ''
        [accounts.test]
        default = true
        display-name = "Alice Foobar"
        email = "${user}@localhost"

        [accounts.test.backend]
        type = "imap"
        host = "localhost"
        port = 143
        encryption.type = "none"
        login = "${user}"
        auth.type = "password"
        auth.raw = "${password}"
      '';

  himalayaBin = pkgs.lib.getExe himalaya-cli;

  # RFC2822 email corpus
  # People: bob, carol, david, eve, frank, grace, helen + service addresses
  # All mail is addressed to alice@localhost
  corpus = [
    # Thread A: "Project Alpha release timeline" (INBOX, 5 messages)
    {
      folder = "INBOX";
      flags = [ ];
      content = ''
        From: Bob Smith <bob@localhost>
        To: alice@localhost
        Subject: Project Alpha release timeline
        Date: Wed, 15 Jan 2025 09:00:00 +0000
        Message-ID: <alpha-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Hi Alice,

        I'd like to discuss the release timeline for Project Alpha.
        We're currently tracking for a Q1 release. Can we sync this
        week to review the remaining milestones?

        Best,
        Bob
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Alice Foobar <alice@localhost>
        To: bob@localhost
        Subject: Re: Project Alpha release timeline
        Date: Wed, 15 Jan 2025 11:00:00 +0000
        Message-ID: <alpha-2@localhost>
        In-Reply-To: <alpha-1@localhost>
        References: <alpha-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Bob,

        Q1 sounds ambitious but doable. Let me check with the team
        and get back to you by end of week.

        Alice
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Carol Davis <carol@localhost>
        To: alice@localhost
        Subject: Re: Project Alpha release timeline
        Date: Wed, 15 Jan 2025 13:00:00 +0000
        Message-ID: <alpha-3@localhost>
        In-Reply-To: <alpha-1@localhost>
        References: <alpha-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Alice,

        I think Q1 is feasible if we scope down the admin panel.
        The core API and client SDK should be solid by February.

        Carol
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: David Lee <david@localhost>
        To: alice@localhost
        Subject: Re: Project Alpha release timeline
        Date: Wed, 15 Jan 2025 14:00:00 +0000
        Message-ID: <alpha-4@localhost>
        In-Reply-To: <alpha-3@localhost>
        References: <alpha-1@localhost> <alpha-3@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Carol makes a good point. If we defer the admin panel to
        a fast-follow release, the Q1 date is realistic. I can
        have the deployment pipeline ready by mid-February.

        David
      '';
    }
    {
      folder = "INBOX";
      flags = [ ];
      content = ''
        From: Bob Smith <bob@localhost>
        To: alice@localhost
        Subject: Re: Project Alpha release timeline
        Date: Thu, 16 Jan 2025 08:45:00 +0000
        Message-ID: <alpha-5@localhost>
        In-Reply-To: <alpha-4@localhost>
        References: <alpha-1@localhost> <alpha-3@localhost> <alpha-4@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Great, let's go with that plan. I'll update the roadmap
        and schedule a kickoff for next Monday.

        Bob
      '';
    }

    # Thread B: "Code review: auth module refactor" (INBOX, 3 messages)
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Eve Martin <eve@localhost>
        To: alice@localhost
        Subject: Code review: auth module refactor
        Date: Tue, 14 Jan 2025 16:00:00 +0000
        Message-ID: <review-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Alice,

        I've pushed the auth module refactor to the feature branch.
        Could you take a look when you get a chance? The main changes
        are switching to JWT and adding refresh token rotation.

        Thanks,
        Eve
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Frank Wilson <frank@localhost>
        To: alice@localhost
        Subject: Re: Code review: auth module refactor
        Date: Tue, 14 Jan 2025 17:30:00 +0000
        Message-ID: <review-2@localhost>
        In-Reply-To: <review-1@localhost>
        References: <review-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        I took a quick look too. The JWT implementation looks solid
        but I have some concerns about the token storage approach.
        Left a few inline comments on the PR.

        Frank
      '';
    }
    {
      folder = "INBOX";
      flags = [
        "\\Seen"
        "\\Answered"
      ];
      content = ''
        From: Eve Martin <eve@localhost>
        To: alice@localhost
        Subject: Re: Code review: auth module refactor
        Date: Wed, 15 Jan 2025 09:00:00 +0000
        Message-ID: <review-3@localhost>
        In-Reply-To: <review-2@localhost>
        References: <review-1@localhost> <review-2@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Frank, good catches. I've addressed your comments and
        switched to httpOnly cookies for token storage. Alice,
        the branch is updated if you want to take another look.

        Eve
      '';
    }

    # Thread C: "Team lunch this Friday?" (INBOX, 2 messages)
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Grace Kim <grace@localhost>
        To: alice@localhost
        Subject: Team lunch this Friday?
        Date: Mon, 13 Jan 2025 12:00:00 +0000
        Message-ID: <lunch-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Hey Alice,

        Want to organize a team lunch this Friday? I was thinking
        that new Thai place on 5th street. Let me know!

        Grace
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Bob Smith <bob@localhost>
        To: alice@localhost
        Subject: Re: Team lunch this Friday?
        Date: Mon, 13 Jan 2025 13:15:00 +0000
        Message-ID: <lunch-2@localhost>
        In-Reply-To: <lunch-1@localhost>
        References: <lunch-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Count me in! Thai sounds great.

        Bob
      '';
    }

    # Thread D: "Q1 budget review" (INBOX, 3 messages)
    {
      folder = "INBOX";
      flags = [
        "\\Seen"
        "\\Flagged"
      ];
      content = ''
        From: Carol Davis <carol@localhost>
        To: alice@localhost
        Subject: Q1 budget review
        Date: Fri, 10 Jan 2025 10:00:00 +0000
        Message-ID: <budget-1@localhost>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="budget-boundary-1"

        --budget-boundary-1
        Content-Type: text/plain; charset="UTF-8"

        Alice,

        Attached is the preliminary Q1 budget spreadsheet.
        Please review the engineering allocation and let me
        know if the numbers look right.

        Carol

        --budget-boundary-1
        Content-Type: text/plain; name="q1-budget.csv"
        Content-Disposition: attachment; filename="q1-budget.csv"
        Content-Transfer-Encoding: base64

        RGVwYXJ0bWVudCxCdWRnZXQsQWxsb2NhdGVkCkVuZ2luZWVyaW5nLDUwMDAwMCwz
        NTAwMDAKRGVzaWduLDIwMDAwMCwxNTAwMDAKTWFya2V0aW5nLDMwMDAwMCwyMDAwMDAK

        --budget-boundary-1--
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: David Lee <david@localhost>
        To: alice@localhost
        Subject: Re: Q1 budget review
        Date: Fri, 10 Jan 2025 14:30:00 +0000
        Message-ID: <budget-2@localhost>
        In-Reply-To: <budget-1@localhost>
        References: <budget-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Carol,

        The engineering numbers look about right, though we may
        need to bump the cloud infrastructure line by 15% given
        the projected traffic growth.

        David
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Carol Davis <carol@localhost>
        To: alice@localhost
        Subject: Re: Q1 budget review
        Date: Mon, 13 Jan 2025 09:00:00 +0000
        Message-ID: <budget-3@localhost>
        In-Reply-To: <budget-2@localhost>
        References: <budget-1@localhost> <budget-2@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Good point David. I've updated the spreadsheet with a
        15% bump on infrastructure. Alice, updated version
        coming your way shortly.

        Carol
      '';
    }

    # Standalone INBOX messages (6 messages)
    {
      folder = "INBOX";
      flags = [ ];
      content = ''
        From: Alice Foobar <alice@localhost>
        To: alice@localhost
        Subject: Have you tried himalaya nvim?
        Date: Thu, 16 Jan 2025 10:00:00 +0000
        Message-ID: <himalaya-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Note to self: check out the himalaya nvim plugin for
        managing email directly from neovim. Looks promising!
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: TechDigest <news@techdigest.io>
        To: alice@localhost
        Subject: Weekly newsletter: Tech digest
        Date: Mon, 13 Jan 2025 06:00:00 +0000
        Message-ID: <newsletter-1@techdigest.io>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        This Week in Tech
        =================

        1. Rust 2025 edition announced
        2. Linux kernel 6.13 released
        3. New advances in local-first software

        Unsubscribe: https://techdigest.io/unsub
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Flagged" ];
      content = ''
        From: Security Team <security@company.com>
        To: alice@localhost
        Subject: Security alert: new login detected
        Date: Wed, 15 Jan 2025 03:22:00 +0000
        Message-ID: <security-1@company.com>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        A new login to your account was detected:

        Location: San Francisco, CA
        Device: Firefox on Linux
        Time: 2025-01-15 03:21 UTC

        If this wasn't you, please reset your password immediately.
      '';
    }
    {
      folder = "INBOX";
      flags = [ "\\Seen" ];
      content = ''
        From: Billing <billing@vendor.com>
        To: alice@localhost
        Subject: Invoice #2024-089 attached
        Date: Tue, 14 Jan 2025 08:00:00 +0000
        Message-ID: <invoice-1@vendor.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="invoice-boundary-1"

        --invoice-boundary-1
        Content-Type: text/plain; charset="UTF-8"

        Dear Alice,

        Please find attached your invoice #2024-089 for
        the current billing period.

        Amount due: $1,250.00
        Due date: February 14, 2025

        Best regards,
        Billing Team

        --invoice-boundary-1
        Content-Type: text/plain; name="invoice-2024-089.txt"
        Content-Disposition: attachment; filename="invoice-2024-089.txt"
        Content-Transfer-Encoding: base64

        SW52b2ljZSAjMjAyNC0wODkKQW1vdW50OiAkMSwyNTAuMDAKRHVlOiAyMDI1LTAy
        LTE0ClN0YXR1czogVW5wYWlk

        --invoice-boundary-1--
      '';
    }
    {
      folder = "INBOX";
      flags = [
        "\\Seen"
        "\\Answered"
      ];
      content = ''
        From: Helen Park <helen@localhost>
        To: alice@localhost
        Subject: Design review notes
        Date: Tue, 14 Jan 2025 15:00:00 +0000
        Message-ID: <design-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Alice,

        Here are my notes from the design review meeting:
        - Navigation should use a sidebar pattern
        - Color palette approved with minor tweaks
        - Mobile breakpoints need rework

        Let me know if I missed anything.

        Helen
      '';
    }
    {
      folder = "INBOX";
      flags = [
        "\\Flagged"
        "\\Seen"
      ];
      content = ''
        From: TechConf Events <events@techconf.io>
        To: alice@localhost
        Subject: Conference talk accepted!
        Date: Thu, 16 Jan 2025 14:00:00 +0000
        Message-ID: <conf-1@techconf.io>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Dear Alice,

        Congratulations! Your talk "Building Email Clients in Rust"
        has been accepted for TechConf 2025.

        Conference dates: March 15-17, 2025
        Your slot: March 16, 2:00 PM

        Please confirm your attendance by January 31.

        Best,
        TechConf Team
      '';
    }

    # Sent folder (2 messages)
    {
      folder = "Sent";
      flags = [ "\\Seen" ];
      content = ''
        From: Alice Foobar <alice@localhost>
        To: bob@localhost
        Subject: Re: Project Alpha release timeline
        Date: Wed, 15 Jan 2025 10:30:00 +0000
        Message-ID: <sent-alpha-2@localhost>
        In-Reply-To: <alpha-1@localhost>
        References: <alpha-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Bob,

        Q1 sounds ambitious but doable. Let me check with the team
        and get back to you by end of week.

        Alice
      '';
    }
    {
      folder = "Sent";
      flags = [ "\\Seen" ];
      content = ''
        From: Alice Foobar <alice@localhost>
        To: eve@localhost
        Subject: Re: Code review: auth module refactor
        Date: Wed, 15 Jan 2025 11:00:00 +0000
        Message-ID: <sent-review-1@localhost>
        In-Reply-To: <review-1@localhost>
        References: <review-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Eve,

        I'll review the branch this afternoon. The JWT approach
        sounds like the right call.

        Alice
      '';
    }

    # Drafts folder (1 message)
    {
      folder = "Drafts";
      flags = [ "\\Draft" ];
      content = ''
        From: Alice Foobar <alice@localhost>
        To: team@localhost
        Subject: Draft: Meeting agenda
        Date: Thu, 16 Jan 2025 16:00:00 +0000
        Message-ID: <draft-1@localhost>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"

        Team meeting agenda for next week:
        1. Project Alpha status update
        2. Q1 budget finalization
        3. New hire onboarding plan
        4. Open discussion
      '';
    }
  ];

  # Unique INBOX subjects (for assertions)
  inboxSubjects = [
    "Project Alpha release timeline"
    "Code review: auth module refactor"
    "Team lunch this Friday?"
    "Q1 budget review"
    "Have you tried himalaya nvim?"
    "Weekly newsletter: Tech digest"
    "Security alert: new login detected"
    "Invoice #2024-089 attached"
    "Design review notes"
    "Conference talk accepted!"
  ];

  injectCorpus =
    let
      saveCommands = builtins.concatStringsSep "\n" (
        pkgs.lib.imap0 (
          i: msg:
          let
            msgFile = pkgs.writeText "msg-${toString i}.eml" msg.content;
            flagCmd =
              if msg.flags != [ ] then
                let
                  flagStr = builtins.concatStringsSep " " msg.flags;
                in
                # sh
                ''
                  doveadm flags add -u ${user} ${flagStr} mailbox ${msg.folder} header Message-ID "$(grep -m1 '^Message-ID:' ${msgFile} | sed 's/Message-ID: <\(.*\)>/\1/' | tr -d ' ')"
                ''
              else
                "";
          in
          ''
            doveadm save -u ${user} -m ${msg.folder} < ${msgFile}
            ${flagCmd}
          ''
        ) corpus
      );
    in
    pkgs.writeScriptBin "inject-corpus" # sh
      ''
        #!${pkgs.runtimeShell}
        set -euo pipefail
        doveadm mailbox create -u ${user} Sent Drafts Archive Trash Spam
        ${saveCommands}
        echo "Corpus injected: ${toString (builtins.length corpus)} messages"
      '';

  recordCliResponses =
    pkgs.writeScriptBin "record-cli-responses" # sh
      ''
        #!${pkgs.runtimeShell}
        set -euo pipefail
        HCLI="${himalayaBin} --config ${himalayaConfig}"
        FIXTURES=/tmp/fixtures
        mkdir -p $FIXTURES/json $FIXTURES/plain

        # JSON commands
        $HCLI --output json account list > $FIXTURES/json/account-list.json
        $HCLI --output json folder list > $FIXTURES/json/folder-list.json
        $HCLI --output json envelope list --folder INBOX --page-size 50 --page 1 > $FIXTURES/json/envelope-list-inbox.json
        $HCLI --output json envelope list --folder Sent --page-size 50 --page 1 > $FIXTURES/json/envelope-list-sent.json
        $HCLI --output json envelope list --folder Drafts --page-size 50 --page 1 > $FIXTURES/json/envelope-list-drafts.json
        $HCLI --output json envelope thread --folder INBOX > $FIXTURES/json/envelope-thread-inbox.json

        # Plain commands - read each INBOX message
        for id in $($HCLI --output json envelope list --folder INBOX --page-size 50 --page 1 | ${pkgs.lib.getExe pkgs.jq} -r '.[].id'); do
          $HCLI message read --folder INBOX "$id" > "$FIXTURES/plain/message-read-$id.txt"
        done

        # Templates
        $HCLI template write > $FIXTURES/plain/template-write.txt

        # Pick first 2 INBOX message IDs for reply/forward templates
        SAMPLE_IDS=$($HCLI --output json envelope list --folder INBOX --page-size 2 --page 1 | ${pkgs.lib.getExe pkgs.jq} -r '.[].id')
        for id in $SAMPLE_IDS; do
          $HCLI template reply --folder INBOX "$id" > "$FIXTURES/plain/template-reply-$id.txt"
          $HCLI template reply --all --folder INBOX "$id" > "$FIXTURES/plain/template-reply-all-$id.txt"
          $HCLI template forward --folder INBOX "$id" > "$FIXTURES/plain/template-forward-$id.txt"
        done

        echo "Fixtures recorded at $FIXTURES"
      '';

  # Shared VM node configuration: alice user + postfix + dovecot
  machineConfig = {
    users.users.${user} = {
      isNormalUser = true;
      description = "Alice Foobar";
      password = password;
      uid = 1000;
    };

    services.postfix.enable = true;

    services.dovecot2 = {
      enable = true;
      protocols = [ "imap" ];
    };
  };

  # Python snippet: wait for mail services and inject the corpus
  testPreamble = # py
    ''
      machine.wait_for_unit("postfix.service")
      machine.wait_for_unit("dovecot2.service")
      machine.wait_for_open_port(143)

      machine.succeed("inject-corpus")
      import time
      time.sleep(2)
    '';
in
{
  inherit
    user
    password
    himalayaConfig
    himalayaBin
    corpus
    inboxSubjects
    injectCorpus
    recordCliResponses
    machineConfig
    testPreamble
    ;
}
