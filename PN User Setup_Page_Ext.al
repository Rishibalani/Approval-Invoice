pageextension 50100 "PN User Setup Page Ext" extends "User Setup"
{
    layout
    {
        addlast(Control1)
        {
            field("PN Entra Object ID"; Rec."PN Entra Object ID")
            {
                ApplicationArea = All;
                Caption = 'Entra Object ID';
                ToolTip = 'The Microsoft Entra object ID of this user. Lets approval notifications reach Teams without a Graph lookup.';
            }
        }
    }
}