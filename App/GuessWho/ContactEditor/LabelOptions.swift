import Contacts

/// Per-field CN constants the LabelPicker offers. Each row type
/// references the slice that applies to it; LabelPicker always appends
/// a "Custom…" option for user-typed labels.
///
/// Service-typed rows (Social, IM) bind their picker to the
/// underlying struct's `.service` field, NOT to the labeled-value
/// `label` slot — CN uses `service` to drive provider icons and link
/// templates. Naming reflects which field a list targets.
enum LabelOptions {
    static let phone: [String] = [
        CNLabelPhoneNumberMobile,
        CNLabelPhoneNumberiPhone,
        CNLabelHome,
        CNLabelWork,
        CNLabelPhoneNumberMain,
        CNLabelPhoneNumberHomeFax,
        CNLabelPhoneNumberWorkFax,
        CNLabelPhoneNumberPager,
        CNLabelOther
    ]

    static let email: [String] = [
        CNLabelHome,
        CNLabelWork,
        CNLabelSchool,
        CNLabelOther
    ]

    static let url: [String] = [
        CNLabelURLAddressHomePage,
        CNLabelHome,
        CNLabelWork,
        CNLabelOther
    ]

    static let address: [String] = [
        CNLabelHome,
        CNLabelWork,
        CNLabelSchool,
        CNLabelOther
    ]

    static let date: [String] = [
        CNLabelDateAnniversary,
        CNLabelOther
    ]

    static let relation: [String] = [
        CNLabelContactRelationFather,
        CNLabelContactRelationMother,
        CNLabelContactRelationParent,
        CNLabelContactRelationBrother,
        CNLabelContactRelationSister,
        CNLabelContactRelationChild,
        CNLabelContactRelationSon,
        CNLabelContactRelationDaughter,
        CNLabelContactRelationFriend,
        CNLabelContactRelationSpouse,
        CNLabelContactRelationPartner,
        CNLabelContactRelationManager,
        CNLabelContactRelationAssistant,
        CNLabelContactRelationColleague,
        CNLabelOther
    ]

    // Social-profile and IM rows surface a service picker (Twitter,
    // Facebook, …) bound to the underlying struct's `.service` field.
    // The labeled-value `label` slot stays empty — CN doesn't expose
    // per-row categories for social or IM in Contacts.app, so neither
    // do we.
    static let socialService: [String] = [
        CNSocialProfileServiceTwitter,
        CNSocialProfileServiceFacebook,
        CNSocialProfileServiceLinkedIn,
        CNSocialProfileServiceGameCenter,
        CNSocialProfileServiceMySpace,
        CNSocialProfileServiceFlickr,
        CNSocialProfileServiceSinaWeibo,
        CNSocialProfileServiceTencentWeibo,
        CNSocialProfileServiceYelp
    ]

    static let imService: [String] = [
        CNInstantMessageServiceAIM,
        CNInstantMessageServiceFacebook,
        CNInstantMessageServiceGaduGadu,
        CNInstantMessageServiceGoogleTalk,
        CNInstantMessageServiceICQ,
        CNInstantMessageServiceJabber,
        CNInstantMessageServiceMSN,
        CNInstantMessageServiceQQ,
        CNInstantMessageServiceSkype,
        CNInstantMessageServiceYahoo
    ]
}
