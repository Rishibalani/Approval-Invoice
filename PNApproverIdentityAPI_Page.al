// =========================================================================
//  PN Approver Identity API
// =========================================================================
//
//  Lets the Azure Function read approver identities and write back the Entra
//  object ID it resolved from Microsoft Graph.
//
//  WHY BUSINESS CENTRAL CANNOT WORK THIS OUT ITSELF
//
//  Business Central knows an approver by User ID and Authentication Email.
//  Teams knows them by Entra object ID. Nothing in Business Central maps one
//  to the other - the only authority is Microsoft Graph.
//
//  So the Function resolves it and writes it here. After that the payload
//  carries the object ID and no Graph call happens again for that person,
//  which matters because Graph is the only part of Teams delivery that needs
//  a consented permission.
//
//  WRITES ARE DELIBERATELY NARROW
//
//  Only entraObjectId is editable. The service account should be able to
//  record what it learned and nothing else - it has no business changing a
//  threshold, a consent flag or a suspension.
// =========================================================================
page 50108 "PN Approver Identity API"
{
    Caption = 'Approver Identity API';
    PageType = API;
    APIPublisher = 'pulsenet';
    APIGroup = 'approvals';
    APIVersion = 'v1.0';
    EntityName = 'pnApproverIdentity';
    EntitySetName = 'pnApproverIdentities';
    SourceTable = "PN Approver Channel Identity";
    DelayedInsert = true;
    Extensible = false;
    InsertAllowed = false;
    DeleteAllowed = false;
    ODataKeyFields = SystemId;

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(systemId; Rec.SystemId)
                {
                    Caption = 'System Id';
                    Editable = false;
                }
                field(userId; Rec."User ID")
                {
                    Caption = 'User Id';
                    Editable = false;
                }
                field(userSecurityId; Rec."User Security ID")
                {
                    Caption = 'User Security Id';
                    Editable = false;
                }
                field(displayName; Rec."Full Name")
                {
                    Caption = 'Display Name';
                    Editable = false;
                }
                field(upn; Rec."Authentication Email")
                {
                    Caption = 'User Principal Name';
                    Editable = false;
                }

                // The only writable field. Everything else is context the
                // Function needs in order to know who it is looking at.
                field(entraObjectId; Rec."Entra Object ID")
                {
                    Caption = 'Entra Object Id';
                }

                field(suspended; Rec.Suspended)
                {
                    Caption = 'Suspended';
                    Editable = false;
                }
                field(consentGiven; Rec."Consent Given")
                {
                    Caption = 'Consent Given';
                    Editable = false;
                }
                field(mobileNumber; Rec."Mobile Number")
                {
                    Caption = 'Mobile Number';
                    Editable = false;
                }
            }
        }
    }

    trigger OnModifyRecord(): Boolean
    var
        UserSetup: Record "User Setup";
    begin
        // Mirror onto User Setup, which is where approver configuration lives
        // and where an administrator would look for it. Keeping both in step
        // here means there is one place that does the syncing, rather than two
        // fields that drift apart because somebody updated the wrong one.
        if Rec."User ID" = '' then
            exit(true);

        if not UserSetup.Get(Rec."User ID") then
            exit(true);

        if UserSetup."PN Entra Object ID" = Rec."Entra Object ID" then
            exit(true);

        UserSetup."PN Entra Object ID" := Rec."Entra Object ID";
        UserSetup.Modify(true);

        exit(true);
    end;
}
