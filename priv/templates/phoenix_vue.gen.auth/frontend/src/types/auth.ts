export interface AuthUser {
  id: string
  primary_email: string
  primary_email_verified: boolean
  display_name: string | null
  avatar_url: string | null
  locale: string
  status: string
  inserted_at: string
  last_login_at: string | null
}

export interface AuthOrganization {
  id: string
  name: string
  slug: string
  status: string
  inserted_at: string
}

export interface AuthMember {
  id: string
  organization_id: string
  user_id: string | null
  email: string | null
  display_name: string | null
  role: string
  status: string
  joined_at: string | null
  last_active_at: string | null
  organization: AuthOrganization | null
}

export interface MePayload {
  user: AuthUser
  current_member: AuthMember | null
  memberships: AuthMember[]
  organization: AuthOrganization | null
}
