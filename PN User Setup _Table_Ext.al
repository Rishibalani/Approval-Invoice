tableextension 50100 "PN User Setup Ext" extends "User Setup"
{
    fields
    {
        field(50100; "PN Entra Object ID"; Guid)
        {
            Caption = 'Entra Object ID';
            DataClassification = OrganizationIdentifiableInformation;
        }
    }
}