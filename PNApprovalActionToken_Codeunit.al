// =========================================================================
//  PN Approval Action Token
// =========================================================================
//
//  Mints the signed token that rides in every approval link Business Central
//  sends by email.
//
//  WHY BUSINESS CENTRAL MINTS ITS OWN
//
//  When Azure sent the email, Azure also minted the token. Now that Business
//  Central sends the email, Business Central has to produce a token the Azure
//  action endpoint will accept - identical algorithm, identical layout,
//  identical shared secret.
//
//  The alternative would be calling Azure to mint one, which reintroduces the
//  network dependency that moving email into Business Central was meant to
//  remove. Eighty lines of AL is a better trade.
//
//  THE FORMAT, WHICH MUST NOT DRIFT
//
//      base64url(payload) "." signature
//
//      payload   = 1.{entryNo}.{approverHash}.{nonce}.{expiryUnix}.{A|R}
//      signature = first 32 hex characters of HMAC-SHA256(payload, secret)
//
//  Azure's ActionTokenService.ValidateAsync parses exactly this. If either
//  side changes, both change in the same commit.
//
//  ON THE SIGNATURE BEING HEX
//
//  Azure mints a base64url signature; this mints hex. Both are the same first
//  sixteen bytes of the same HMAC, written differently.
//
//  AL can produce a hex HMAC in one call. Producing base64url of a TRUNCATED
//  HMAC would mean converting hex to bytes to base64 by hand, which is thirty
//  lines of bit-shuffling for no gain. The Azure validator accepts both
//  encodings instead - a five-line change there rather than thirty fragile
//  ones here.
//
//  WHY THE APPROVER IS HASHED RATHER THAN NAMED
//
//  The token travels in a URL, which lands in browser history, proxy logs and
//  referrer headers. Putting priya@company.com there leaks an identity on
//  every click. A keyed hash binds the token to her just as tightly and
//  reveals nothing - and because it is keyed, nobody can build a lookup table
//  of your staff directory from captured links.
// =========================================================================
codeunit 50106 "PN Approval Action Token"
{
    Access = Internal;

    var
        TokenVersionTok: Label '1', Locked = true;
        SignatureHexLength: Integer;
        IsoFormatErr: Label 'Could not read a timestamp while building an approval link. Expected an ISO 8601 value such as 2026-09-15T12:30:52Z but got "%1". This is a fault in PN Approval Action Token.', Comment = '%1 = the value received';
        NoSecretErr: Label 'No action token signing secret is stored. On the Approval Integration Setup page, enter the Action Token Secret - it must match ActionToken__SigningSecret on the Azure Function exactly.';

    trigger OnRun()
    begin
    end;

    /// <summary>
    /// Builds a token for one approval entry, one approver, one action.
    ///
    /// Approve and Reject get separate tokens with separate nonces, so using
    /// one does not silently disable the other.
    /// </summary>
    procedure Mint(ApprovalEntryNo: Integer; ApproverEmail: Text; IsApprove: Boolean) Token: Text
    var
        Setup: Record "PN Approval Integration Setup";
        Secret: Text;
        Payload: Text;
        Nonce: Text;
        ExpiryUnix: BigInteger;
        ActionChar: Text;
    begin
        Setup.GetSetup();
        Secret := Setup.GetActionTokenSecret();

        if Secret = '' then
            Error(NoSecretErr);

        Nonce := LowerCase(DelChr(Format(CreateGuid(), 0, 4), '=', '{}-'));
        Nonce := CopyStr(Nonce, 1, 16);

        // Global switch. On: Action Link Lifetime from setup (* 60 * 1000 is
        // minutes to ms). Off: NoExpiry (0), which Azure reads as "never
        // expires" - the value is inside the signed payload, so it cannot be
        // added to an expiring token without the secret.
        if Setup."Action Link Expiry Enabled" then
            ExpiryUnix := ToUnixSeconds(CurrentDateTime() + (Setup.GetActionTokenTtlMinutes() * 60 * 1000))
        else
            ExpiryUnix := 0; // Wire contract with Azure ActionTokenService.NoExpiry: 0 = never expires.

        if IsApprove then
            ActionChar := 'A'
        else
            ActionChar := 'R';

        Payload :=
            TokenVersionTok + '.' +
            Format(ApprovalEntryNo) + '.' +
            HashApprover(ApproverEmail, Secret) + '.' +
            Nonce + '.' +
            Format(ExpiryUnix) + '.' +
            ActionChar;

        exit(Base64UrlEncode(Payload) + '.' + SignPayload(Payload, Secret));
    end;

    /// <summary>
    /// The full URL an approval button points at.
    /// </summary>
    procedure BuildActionUrl(ApprovalEntryNo: Integer; ApproverEmail: Text; IsApprove: Boolean) Url: Text
    var
        Setup: Record "PN Approval Integration Setup";
        Separator: Text;
    begin
        Setup.GetSetup();

        if Setup."Action Endpoint URL" = '' then
            exit('');

        if StrPos(Setup."Action Endpoint URL", '?') > 0 then
            Separator := '&'
        else
            Separator := '?';

        exit(Setup."Action Endpoint URL" + Separator + 't=' +
             Mint(ApprovalEntryNo, ApproverEmail, IsApprove));
    end;

    // ------------------------------------------------------------------
    //  Primitives
    // ------------------------------------------------------------------

    /// <summary>
    /// First sixteen bytes of HMAC-SHA256, as thirty-two lowercase hex
    /// characters.
    ///
    /// Truncating to 128 bits is deliberate and safe here: forging one needs
    /// 2^128 work, the token expires after Action Link Lifetime when expiry is on, and the nonce
    /// store means even a valid token works once. The reason for truncating at
    /// all is WhatsApp, where a quick-reply payload is capped at 256
    /// characters - a full-length signature plus the payload would not fit.
    ///
    /// VERSION NOTE: the third argument is the HashAlgorithmType option
    /// ordinal. In the System Application the HMAC option list is HMACMD5,
    /// HMACSHA1, HMACSHA256, HMACSHA384, HMACSHA512 - so 2 is HMACSHA256. If
    /// your Business Central version exposes an enum overload instead, this
    /// procedure is the only place to change.
    /// </summary>
    local procedure SignPayload(Payload: Text; Secret: Text): Text
    var
        CryptographyManagement: Codeunit "Cryptography Management";
        FullHex: Text;
    begin
        FullHex := LowerCase(CryptographyManagement.GenerateHash(Payload, Secret, 2));
        exit(CopyStr(FullHex, 1, 32));
    end;

    /// <summary>
    /// Eight hex characters derived from the approver's email.
    ///
    /// Keyed, not plain. A plain SHA-256 of an email address is trivially
    /// reversed with a staff list, so an attacker holding a captured link
    /// could work out whose it was. Keying it means they cannot.
    ///
    /// Lowercased first, because email addresses are case-insensitive in
    /// practice and Azure lowercases before hashing too. A capitalised UPN
    /// would otherwise produce a different hash and fail the identity check.
    /// </summary>
    local procedure HashApprover(ApproverEmail: Text; Secret: Text): Text
    var
        CryptographyManagement: Codeunit "Cryptography Management";
        FullHex: Text;
    begin
        FullHex := LowerCase(CryptographyManagement.GenerateHash(
            LowerCase(DelChr(ApproverEmail, '<>', ' ')), Secret, 2));

        exit(CopyStr(FullHex, 1, 8));
    end;

    /// <summary>
    /// Base64, made URL-safe: plus becomes minus, slash becomes underscore,
    /// and the padding is dropped. Azure reverses this before verifying.
    /// </summary>
    local procedure Base64UrlEncode(Value: Text): Text
    var
        Base64Convert: Codeunit "Base64 Convert";
        Encoded: Text;
    begin
        Encoded := Base64Convert.ToBase64(Value);
        Encoded := ConvertStr(Encoded, '+/', '-_');
        exit(DelChr(Encoded, '>', '='));
    end;

    /// <summary>
    /// Seconds since 1 January 1970 UTC.
    ///
    /// Derived by parsing the ISO 8601 rendering rather than by subtracting
    /// DateTime values, and that choice matters.
    ///
    /// AL DateTime arithmetic happens in the service tier's local clock.
    /// CreateDateTime(1 Jan 1970, 0T) is midnight LOCAL, so subtracting it
    /// from CurrentDateTime yields a figure that differs from true Unix time
    /// by the server's UTC offset. On a Canadian environment that is five to
    /// eight hours - enough to mint every token already expired, or to give
    /// each one several extra hours of life. Neither failure announces itself.
    ///
    /// Format(dt, 0, 9) is the XML format, which is always UTC and always
    /// shaped yyyy-MM-ddTHH:mm:ss. Parsing it is a few more lines and has no
    /// timezone in it at all.
    /// </summary>
    local procedure ToUnixSeconds(Value: DateTime): BigInteger
    var
        Iso: Text;
        DatePart: Date;
        Years: Integer;
        Months: Integer;
        Days: Integer;
        Hours: Integer;
        Minutes: Integer;
        Seconds: Integer;
        DaysSinceEpoch: Integer;
    begin
        Iso := Format(Value, 0, 9);

        // Guarded, because a bare Evaluate on an unexpected string throws
        // "The value "" can't be evaluated into type Integer" - an exception
        // that surfaces through OData as a 400 naming no field, no procedure
        // and no object. Whatever calls this deserves a message it can act on.
        if StrLen(Iso) < 19 then
            Error(IsoFormatErr, Iso);

        // "2026-09-15T12:30:52.437Z"
        //  1234 67 90 23 56 89
        if not Evaluate(Years, CopyStr(Iso, 1, 4)) then
            Error(IsoFormatErr, Iso);
        if not Evaluate(Months, CopyStr(Iso, 6, 2)) then
            Error(IsoFormatErr, Iso);
        if not Evaluate(Days, CopyStr(Iso, 9, 2)) then
            Error(IsoFormatErr, Iso);
        if not Evaluate(Hours, CopyStr(Iso, 12, 2)) then
            Error(IsoFormatErr, Iso);
        if not Evaluate(Minutes, CopyStr(Iso, 15, 2)) then
            Error(IsoFormatErr, Iso);
        if not Evaluate(Seconds, CopyStr(Iso, 18, 2)) then
            Error(IsoFormatErr, Iso);

        // Date subtraction returns whole days and carries no time or zone, so
        // it is safe in a way DateTime subtraction is not.
        DatePart := DMY2Date(Days, Months, Years);
        DaysSinceEpoch := DatePart - DMY2Date(1, 1, 1970);

        exit((DaysSinceEpoch * 86400) + (Hours * 3600) + (Minutes * 60) + Seconds);
    end;
}
