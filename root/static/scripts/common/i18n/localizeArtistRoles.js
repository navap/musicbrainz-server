/*
 * @flow
 * Copyright (C) 2019 MetaBrainz Foundation
 *
 * This file is part of MusicBrainz, the open internet music database,
 * and is licensed under the GPL version 2, or (at your option) any
 * later version: http://www.gnu.org/licenses/gpl-2.0.txt
 */


import {l_relationships} from './relationships';

function localizeArtistRoles(roles: $ReadOnlyArray<string>):
  $ReadOnlyArray<string> {
  return roles.map(role => l_relationships(role));
}

export default localizeArtistRoles;
