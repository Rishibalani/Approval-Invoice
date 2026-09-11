page 50102 "PN Approver Channel Identity"
{
    Caption = 'Approver Channel Identity';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = None;
    SourceTable = "PN Approver Channel Identity";

    layout
    {
        area(Content)
        {
            group(Identity)
            {
                Caption = 'Identity';
                field("User Security ID"; Rec."User Security ID") { ApplicationArea = All; }
                field("User ID"; Rec."User ID") { ApplicationArea = All; }
                field("Full Name"; Rec."Full Name") { ApplicationArea = All; }
                field("Authentication Email"; Rec."Authentication Email") { ApplicationArea = All; }
                field("Entra Object ID"; Rec."Entra Object ID")
                {
                    ApplicationArea = All;
                    ToolTip = 'Cached by the Azure Function after its first Microsoft Graph lookup. Leave blank and it fills itself in.';
                }
                field("Employee No."; Rec."Employee No.")
                {
                    ApplicationArea = All;
                    ToolTip = 'Optional. Only used to fall back to an employee email or mobile number when the user record has none.';
                }
            }
            group(Channels)
            {
                Caption = 'Contact Details';
                InstructionalText = 'Which channels are in use is set globally on Approval Channel Setup, not here.';
                field("Mobile Number"; Rec."Mobile Number") { ApplicationArea = All; }
            }
            group(Policy)
            {
                Caption = 'Policy';
                field("Personal High Value Threshold"; Rec."Personal High Value Threshold") { ApplicationArea = All; }
                field(Suspended; Rec.Suspended) { ApplicationArea = All; }
                field("Consent Given"; Rec."Consent Given") { ApplicationArea = All; }
                field("Consent Date"; Rec."Consent Date") { ApplicationArea = All; }
            }
        }
    }
}
