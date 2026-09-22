// =========================================================================
//  PN Approval Upgrade
// =========================================================================
//
//  Populates the setup fields that replaced hardcoded values in code.
//
//  InitValue only applies when a record is initialised. A setup row that
//  already existed before these fields were added comes through the schema
//  upgrade with zero, blank or false in every new field - and because none of
//  them has a code-level fallback any more, dispatch would stop with a
//  "must have a value" error. This writes the values the code used to
//  hardcode (each field's InitValue), so behaviour after the upgrade is
//  exactly what it was before.
//
//  Guarded by an upgrade tag so it runs once per company; the table procedure
//  it calls is itself idempotent. The tag is registered for new companies by
//  the OnGetPerCompanyUpgradeTags subscriber in PN Approval Event Subscriber.
// =========================================================================
codeunit 50108 "PN Approval Upgrade"
{
    Subtype = Upgrade;
    Access = Internal;
    Permissions = tabledata "PN Approval Integration Setup" = rm;

    trigger OnUpgradePerCompany()
    var
        Setup: Record "PN Approval Integration Setup";
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        if UpgradeTag.HasUpgradeTag(Setup.GetConfigFieldsUpgradeTag()) then
            exit;

        // No row means nothing was ever configured in this company; the row is
        // created by GetSetup() on first use, with InitValue applied.
        Setup.ApplyConfigDefaultsToExistingRow();

        UpgradeTag.SetUpgradeTag(Setup.GetConfigFieldsUpgradeTag());
    end;
}
