enum VoyageRole { lead, sailor, sweeper, marker }

extension VoyageRoleLabel on VoyageRole {
  String get label => switch (this) {
    VoyageRole.lead => 'Lead',
    VoyageRole.sailor => 'Sailor',
    VoyageRole.sweeper => 'Sweeper',
    VoyageRole.marker => 'Marker',
  };
}
