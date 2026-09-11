// =========================================================================
//  PN Approver Channel Identity
// =========================================================================
//
//  The identity anchor for the whole solution, and the thing that most needs
//  to be different from the existing timesheet/expense implementation.
//
//  Timesheet approvers are employees, so keying preferences on Employee No.
//  works. Invoice approvers are finance and procurement people who frequently
//  do not exist in the Employee table at all. They do exist in the User table,
//  and the Approval Entry carries their Approver ID, so User Security ID is
//  the only key that is guaranteed to resolve.
//
//  This table answers one question for the dispatcher: given the User Security
//  ID on an Approval Entry, where do I send the card and is this person even
//  opted in?
// =========================================================================
table 50100 "PN Approver Channel Identity"
{
    Caption = 'Approver Channel Identity';
    DataClassification = CustomerContent;
    DrillDownPageId = "PN Approver Channel Identities";
    LookupPageId = "PN Approver Channel Identities";

    fields
    {
        field(1; "User Security ID"; Guid)
        {
            Caption = 'User Security ID';
            TableRelation = User."User Security ID";
            NotBlank = true;

            trigger OnValidate()
            var
                User: Record User;
            begin
                if User.Get("User Security ID") then begin
                    "User ID" := User."User Name";
                    if "Authentication Email" = '' then
                        "Authentication Email" := User."Authentication Email";
                    if "Full Name" = '' then
                        "Full Name" := User."Full Name";
                end;
            end;
        }
        field(2; "User ID"; Code[50])
        {
            Caption = 'User ID';
            Editable = false;
        }
        field(3; "Full Name"; Text[80])
        {
            Caption = 'Full Name';
        }
        field(4; "Authentication Email"; Text[250])
        {
            Caption = 'Authentication Email (UPN)';
            ExtendedDatatype = EMail;
            ToolTip = 'The user principal name. This is what Microsoft Graph resolves into an Entra object ID for Teams delivery, and it is the mailbox an actionable email is sent to.';
        }
        field(6; "Employee No."; Code[20])
        {
            Caption = 'Employee No.';
            TableRelation = Employee;
            ToolTip = 'Optional enrichment only. There is no standard link between a Business Central user and an employee, so this is matched on email and can be wrong. It is never the key - User Security ID is.';

            trigger OnValidate()
            var
                Employee: Record Employee;
            begin
                if "Employee No." = '' then
                    exit;
                if not Employee.Get("Employee No.") then
                    exit;

                if "Mobile Number" = '' then
                    "Mobile Number" := CopyStr(Employee."Mobile Phone No.", 1, MaxStrLen("Mobile Number"));
                if "Full Name" = '' then
                    "Full Name" := CopyStr(Employee.FullName(), 1, MaxStrLen("Full Name"));
            end;
        }

        field(5; "Entra Object ID"; Guid)
        {
            Caption = 'Entra Object ID';
            ToolTip = 'Cached Entra ID object ID. Leave blank to have the Azure Function resolve it from the UPN via Graph on first dispatch and write it back.';
        }

        // ---------------------------------------------------------------
        //  Channel opt-in
        // ---------------------------------------------------------------
        field(20; "Teams Enabled"; Boolean)
        {
            Caption = 'Teams Enabled';
            ObsoleteState = Pending;
            ObsoleteReason = 'Channel selection moved to the global toggles on PN Approval Integration Setup.';
            ObsoleteTag = '1.1';
        }
        field(21; "Outlook Enabled"; Boolean)
        {
            Caption = 'Outlook Enabled';
            ObsoleteState = Pending;
            ObsoleteReason = 'Channel selection moved to the global toggles on PN Approval Integration Setup.';
            ObsoleteTag = '1.1';
        }
        field(22; "WhatsApp Enabled"; Boolean)
        {
            Caption = 'WhatsApp Enabled';
            ObsoleteState = Pending;
            ObsoleteReason = 'Channel selection moved to the global toggles on PN Approval Integration Setup.';
            ObsoleteTag = '1.1';
        }
        field(23; "Fallback Channel"; Enum "PN Approval Channel")
        {
            Caption = 'Fallback Channel';
            ObsoleteState = Pending;
            ObsoleteReason = 'Fallback is now global, on PN Approval Integration Setup.';
            ObsoleteTag = '1.1';
        }
        field(24; "Mobile Number"; Text[30])
        {
            Caption = 'Mobile Number (E.164)';
            ExtendedDatatype = PhoneNo;
            ToolTip = 'Reserved for WhatsApp. Must be in E.164 format including the country code, for example +919876543210.';

            trigger OnValidate()
            begin
                if "Mobile Number" = '' then
                    exit;
                if CopyStr("Mobile Number", 1, 1) <> '+' then
                    Error(E164Err);
            end;
        }

        // ---------------------------------------------------------------
        //  Per-approver policy overrides
        // ---------------------------------------------------------------
        field(40; "Personal High Value Threshold"; Decimal)
        {
            Caption = 'Personal High Value Threshold (LCY)';
            MinValue = 0;
            AutoFormatType = 1;
            ToolTip = 'Overrides the global threshold for this approver, if lower. The stricter of the two always wins - a personal setting can tighten the control, never loosen it.';
        }
        field(41; "Suspended"; Boolean)
        {
            Caption = 'Suspended';
            ToolTip = 'Stops all channel delivery for this approver without deleting their preferences. Use while someone is on leave; their approvals then happen in Business Central as normal.';
        }
        field(42; "Consent Given"; Boolean)
        {
            Caption = 'Consent Recorded';
            ToolTip = 'Records that the approver was told their name, the counterparty and the invoice amount will be transmitted to the selected channels. Relevant to GDPR and the India DPDP Act.';
        }
        field(43; "Consent Date"; DateTime)
        {
            Caption = 'Consent Date';
            Editable = false;
        }
    }

    keys
    {
        key(PK; "User Security ID") { Clustered = true; }
        key(ByUserId; "User ID") { }
    }

    fieldgroups
    {
        fieldgroup(DropDown; "User ID", "Full Name", "Authentication Email") { }
        fieldgroup(Brick; "Full Name", "User ID", "Authentication Email") { }
    }

    var
        E164Err: Label 'The mobile number must be in E.164 format and start with a plus sign, for example +919876543210.';

    trigger OnModify()
    begin
        if "Consent Given" and ("Consent Date" = 0DT) then
            "Consent Date" := CurrentDateTime();
        if not "Consent Given" then
            "Consent Date" := 0DT;
    end;

    /// <summary>
    /// Returns the identity row for an approver, creating a default one from the
    /// User table if it does not exist. Auto-creation means the integration works
    /// for a new approver on day one; the row can be tuned afterwards.
    /// </summary>
    procedure GetOrCreate(ApproverUserSecurityId: Guid): Boolean
    var
        User: Record User;
    begin
        if Get(ApproverUserSecurityId) then
            exit(true);

        if not User.Get(ApproverUserSecurityId) then
            exit(false);

        Init();
        Validate("User Security ID", ApproverUserSecurityId);
        Insert(true);
        exit(true);
    end;

    /// <summary>
    /// The effective high value threshold for this approver: the stricter of the
    /// global setting and any personal override. A personal value of zero means
    /// "no override", not "no threshold".
    /// </summary>
    /// <summary>
    /// The approver's email, resolved cheapest source first.
    ///
    ///   1. Authentication Email on this record - the cached UPN
    ///   2. The User table - authoritative for a Business Central user
    ///   3. The Employee card - only if an employee is linked
    ///
    /// Invoice approvers are finance and procurement people who frequently do
    /// not exist in the Employee table at all, which is why the User table
    /// comes first and Employee is a fallback rather than the source.
    /// </summary>
    procedure ResolveEmail() Email: Text[250]
    var
        User: Record User;
        Employee: Record Employee;
    begin
        if "Authentication Email" <> '' then
            exit("Authentication Email");

        if User.Get("User Security ID") then
            if User."Authentication Email" <> '' then begin
                // Cache it so the next dispatch skips the lookup.
                "Authentication Email" := User."Authentication Email";
                if Modify(true) then;
                exit("Authentication Email");
            end;

        if "Employee No." <> '' then
            if Employee.Get("Employee No.") then begin
                if Employee."Company E-Mail" <> '' then
                    exit(CopyStr(Employee."Company E-Mail", 1, 250));
                if Employee."E-Mail" <> '' then
                    exit(CopyStr(Employee."E-Mail", 1, 250));
            end;

        exit('');
    end;

    /// <summary>
    /// Attempts to link an Employee record by matching company email against
    /// the user's authentication email.
    ///
    /// A heuristic, and it will sometimes be wrong - Business Central has no
    /// standard field joining a user to an employee. That is precisely why
    /// Employee No. is editable: when the guess is wrong, somebody fixes it in
    /// ten seconds instead of filing a bug.
    /// </summary>
    procedure TryMatchEmployee(): Boolean
    var
        Employee: Record Employee;
        Email: Text[250];
    begin
        if "Employee No." <> '' then
            exit(true);

        Email := ResolveEmail();
        if Email = '' then
            exit(false);

        Employee.SetRange("Company E-Mail", Email);
        if Employee.FindFirst() then begin
            Validate("Employee No.", Employee."No.");
            Modify(true);
            exit(true);
        end;

        Employee.Reset();
        Employee.SetRange("E-Mail", Email);
        if Employee.FindFirst() then begin
            Validate("Employee No.", Employee."No.");
            Modify(true);
            exit(true);
        end;

        exit(false);
    end;

    /// <summary>
    /// Stores the Entra object ID the Azure Function resolved via Graph, so
    /// the lookup happens once per approver rather than once per dispatch.
    /// Graph is the only part of Teams delivery needing a consented
    /// permission, so it is worth calling as rarely as possible.
    /// </summary>
    procedure CacheEntraObjectId(NewObjectId: Guid)
    begin
        if IsNullGuid(NewObjectId) then
            exit;
        if "Entra Object ID" = NewObjectId then
            exit;

        "Entra Object ID" := NewObjectId;
        Modify(true);
    end;

    procedure EffectiveHighValueThreshold(GlobalThreshold: Decimal): Decimal
    begin
        if "Personal High Value Threshold" = 0 then
            exit(GlobalThreshold);
        if GlobalThreshold = 0 then
            exit("Personal High Value Threshold");
        if "Personal High Value Threshold" < GlobalThreshold then
            exit("Personal High Value Threshold");
        exit(GlobalThreshold);
    end;

}
