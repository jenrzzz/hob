SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: app_clearance_rank(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_clearance_rank() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
  SELECT rank FROM realms WHERE slug = current_setting('app.clearance', true)
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_messages (
    id character varying NOT NULL,
    sender_id bigint NOT NULL,
    recipient_id bigint NOT NULL,
    body text NOT NULL,
    sentinel_request_id character varying NOT NULL,
    read_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id bigint NOT NULL,
    token_digest character varying NOT NULL,
    principal_id bigint NOT NULL,
    surface character varying NOT NULL,
    default_clearance character varying NOT NULL,
    last_used_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: api_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.api_keys_id_seq OWNED BY public.api_keys.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: board_posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.board_posts (
    id character varying NOT NULL,
    thread_id character varying NOT NULL,
    thread_slug character varying NOT NULL,
    thread_topic character varying NOT NULL,
    realm character varying NOT NULL,
    body text NOT NULL,
    links jsonb DEFAULT '[]'::jsonb NOT NULL,
    sender_agent_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    surface character varying NOT NULL
);

ALTER TABLE ONLY public.board_posts FORCE ROW LEVEL SECURITY;


--
-- Name: branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branches (
    id bigint NOT NULL,
    conversation_id character varying NOT NULL,
    name character varying NOT NULL,
    head_hash character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: branches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.branches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: branches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.branches_id_seq OWNED BY public.branches.id;


--
-- Name: budget_backends; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_backends (
    id character varying NOT NULL,
    name character varying NOT NULL,
    kind character varying NOT NULL,
    principal_id bigint NOT NULL,
    realm character varying NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.budget_backends FORCE ROW LEVEL SECURITY;


--
-- Name: calendar_contributors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendar_contributors (
    id bigint NOT NULL,
    owner_id bigint NOT NULL,
    agent_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: calendar_contributors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendar_contributors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendar_contributors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendar_contributors_id_seq OWNED BY public.calendar_contributors.id;


--
-- Name: calendar_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendar_events (
    id character varying NOT NULL,
    source_agent_id bigint NOT NULL,
    owner_id bigint NOT NULL,
    calendar character varying DEFAULT ''::character varying NOT NULL,
    uid character varying NOT NULL,
    start_at timestamp(6) without time zone NOT NULL,
    end_at timestamp(6) without time zone NOT NULL,
    all_day boolean DEFAULT false NOT NULL,
    busy boolean DEFAULT true NOT NULL,
    status character varying,
    title character varying,
    location character varying,
    visibility character varying DEFAULT 'free_busy'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: capabilities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capabilities (
    id bigint NOT NULL,
    name character varying NOT NULL,
    description text NOT NULL,
    input_schema jsonb DEFAULT '{"type": "object", "properties": {}}'::jsonb NOT NULL,
    kind character varying DEFAULT 'act'::character varying NOT NULL,
    realm character varying NOT NULL,
    venue character varying NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: capabilities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.capabilities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: capabilities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.capabilities_id_seq OWNED BY public.capabilities.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id character varying NOT NULL,
    surface character varying NOT NULL,
    realm character varying NOT NULL,
    taint_realm character varying NOT NULL,
    title character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    kind character varying DEFAULT 'chat'::character varying NOT NULL
);

ALTER TABLE ONLY public.conversations FORCE ROW LEVEL SECURITY;


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id bigint NOT NULL,
    principal_id bigint NOT NULL,
    platform character varying DEFAULT 'ios'::character varying NOT NULL,
    token character varying NOT NULL,
    environment character varying NOT NULL,
    name character varying,
    app_version character varying,
    last_seen_at timestamp(6) without time zone,
    last_pushed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: devices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.devices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: devices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.devices_id_seq OWNED BY public.devices.id;


--
-- Name: message_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_nodes (
    content_hash character varying NOT NULL,
    conversation_id character varying NOT NULL,
    parent_hash character varying,
    realm character varying NOT NULL,
    role character varying NOT NULL,
    speaker character varying,
    kind character varying DEFAULT 'text'::character varying NOT NULL,
    content text NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    prompt_snapshot_hash character varying,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.message_nodes FORCE ROW LEVEL SECURITY;


--
-- Name: missions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.missions (
    id character varying NOT NULL,
    assignee_id bigint NOT NULL,
    created_by_id bigint,
    title character varying NOT NULL,
    brief text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    realm character varying NOT NULL,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    lease_token character varying,
    leased_at timestamp(6) without time zone,
    lease_expires_at timestamp(6) without time zone,
    result jsonb,
    error text,
    sentinel_request_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.missions FORCE ROW LEVEL SECURITY;


--
-- Name: model_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_prices (
    model character varying NOT NULL,
    input numeric(10,4) DEFAULT 0.0 NOT NULL,
    output numeric(10,4) DEFAULT 0.0 NOT NULL,
    cache_read numeric(10,4) DEFAULT 0.0 NOT NULL,
    cache_write numeric(10,4) DEFAULT 0.0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    note character varying,
    effective_from date
);


--
-- Name: model_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_roles (
    id bigint NOT NULL,
    role character varying NOT NULL,
    chain jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: model_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_roles_id_seq OWNED BY public.model_roles.id;


--
-- Name: personas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personas (
    id character varying NOT NULL,
    key character varying NOT NULL,
    name character varying NOT NULL,
    prompt jsonb DEFAULT '{}'::jsonb NOT NULL,
    model_role character varying,
    voice_id character varying,
    card_import jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: petitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.petitions (
    id character varying NOT NULL,
    principal_id bigint NOT NULL,
    want text NOT NULL,
    capability_name character varying,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    reason text,
    surface character varying NOT NULL,
    realm character varying NOT NULL,
    on_mission_id character varying,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    action character varying,
    decided_by character varying,
    rationale text,
    decider_id bigint,
    review jsonb DEFAULT '{}'::jsonb NOT NULL,
    effect character varying,
    spec jsonb DEFAULT '{}'::jsonb NOT NULL,
    sentinel_policy_id bigint,
    mission_id character varying,
    pull_request character varying,
    error text,
    decided_at timestamp(6) without time zone,
    settled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.petitions FORCE ROW LEVEL SECURITY;


--
-- Name: presets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.presets (
    id bigint NOT NULL,
    key character varying NOT NULL,
    name character varying NOT NULL,
    stages jsonb DEFAULT '[]'::jsonb NOT NULL,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: presets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.presets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: presets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.presets_id_seq OWNED BY public.presets.id;


--
-- Name: principals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.principals (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    name character varying NOT NULL,
    max_clearance character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    channel character varying,
    accepts_lower_messages boolean DEFAULT false NOT NULL
);


--
-- Name: principals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.principals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: principals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.principals_id_seq OWNED BY public.principals.id;


--
-- Name: prompt_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompt_snapshots (
    digest character varying NOT NULL,
    conversation_id character varying NOT NULL,
    realm character varying NOT NULL,
    assembled jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.prompt_snapshots FORCE ROW LEVEL SECURITY;


--
-- Name: providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.providers (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    kind character varying NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    transient boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: providers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.providers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: providers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.providers_id_seq OWNED BY public.providers.id;


--
-- Name: realms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.realms (
    slug character varying NOT NULL,
    rank integer NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sentinel_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentinel_policies (
    id bigint NOT NULL,
    principal_id bigint,
    capability character varying DEFAULT '*'::character varying NOT NULL,
    effect character varying NOT NULL,
    constraints jsonb DEFAULT '{}'::jsonb NOT NULL,
    limits jsonb DEFAULT '{}'::jsonb NOT NULL,
    guidance text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sentinel_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sentinel_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sentinel_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sentinel_policies_id_seq OWNED BY public.sentinel_policies.id;


--
-- Name: sentinel_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentinel_requests (
    id character varying NOT NULL,
    principal_id bigint NOT NULL,
    capability_id bigint NOT NULL,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    reason text,
    surface character varying NOT NULL,
    realm character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    decision character varying,
    decided_by character varying,
    rationale text,
    decider_id bigint,
    review jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb,
    error text,
    mission_id character varying,
    on_mission_id character varying,
    decided_at timestamp(6) without time zone,
    executed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.sentinel_requests FORCE ROW LEVEL SECURITY;


--
-- Name: todo_backends; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.todo_backends (
    id character varying NOT NULL,
    name character varying NOT NULL,
    kind character varying NOT NULL,
    principal_id bigint NOT NULL,
    realm character varying NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    "primary" boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.todo_backends FORCE ROW LEVEL SECURITY;


--
-- Name: usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events (
    id bigint NOT NULL,
    principal_id bigint,
    surface character varying,
    role character varying,
    provider character varying,
    model character varying,
    units jsonb DEFAULT '{}'::jsonb NOT NULL,
    cost numeric(10,6),
    ref character varying,
    created_at timestamp(6) without time zone NOT NULL,
    operation character varying,
    status character varying DEFAULT 'success'::character varying NOT NULL,
    duration_ms integer,
    error text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    snapshot_digest character varying
);


--
-- Name: usage_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usage_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usage_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usage_events_id_seq OWNED BY public.usage_events.id;


--
-- Name: ward_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ward_checks (
    slug character varying NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    interval_seconds integer DEFAULT 604800 NOT NULL,
    grace_seconds integer DEFAULT 86400 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_completed_at timestamp(6) without time zone,
    last_run_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ward_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ward_findings (
    id character varying NOT NULL,
    check_slug character varying NOT NULL,
    fingerprint character varying NOT NULL,
    level character varying NOT NULL,
    subject character varying NOT NULL,
    message text NOT NULL,
    occurrences integer DEFAULT 1 NOT NULL,
    first_seen_at timestamp(6) without time zone NOT NULL,
    last_seen_at timestamp(6) without time zone NOT NULL,
    first_run_id character varying,
    last_run_id character varying,
    resolved_at timestamp(6) without time zone,
    resolved_run_id character varying,
    acknowledged_at timestamp(6) without time zone,
    acknowledged_by_id bigint,
    ack_note text,
    ack_until timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ward_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ward_notes (
    id character varying NOT NULL,
    subject character varying NOT NULL,
    body text NOT NULL,
    author_id bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ward_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ward_runs (
    id character varying NOT NULL,
    check_slug character varying NOT NULL,
    principal_id bigint,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    exit_code integer,
    complete boolean DEFAULT false NOT NULL,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    diff jsonb DEFAULT '{}'::jsonb NOT NULL,
    triage jsonb,
    mission_id character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys ALTER COLUMN id SET DEFAULT nextval('public.api_keys_id_seq'::regclass);


--
-- Name: branches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches ALTER COLUMN id SET DEFAULT nextval('public.branches_id_seq'::regclass);


--
-- Name: calendar_contributors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_contributors ALTER COLUMN id SET DEFAULT nextval('public.calendar_contributors_id_seq'::regclass);


--
-- Name: capabilities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capabilities ALTER COLUMN id SET DEFAULT nextval('public.capabilities_id_seq'::regclass);


--
-- Name: devices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices ALTER COLUMN id SET DEFAULT nextval('public.devices_id_seq'::regclass);


--
-- Name: model_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_roles ALTER COLUMN id SET DEFAULT nextval('public.model_roles_id_seq'::regclass);


--
-- Name: presets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.presets ALTER COLUMN id SET DEFAULT nextval('public.presets_id_seq'::regclass);


--
-- Name: principals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principals ALTER COLUMN id SET DEFAULT nextval('public.principals_id_seq'::regclass);


--
-- Name: providers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers ALTER COLUMN id SET DEFAULT nextval('public.providers_id_seq'::regclass);


--
-- Name: sentinel_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_policies ALTER COLUMN id SET DEFAULT nextval('public.sentinel_policies_id_seq'::regclass);


--
-- Name: usage_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ALTER COLUMN id SET DEFAULT nextval('public.usage_events_id_seq'::regclass);


--
-- Name: agent_messages agent_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_messages
    ADD CONSTRAINT agent_messages_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: board_posts board_posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.board_posts
    ADD CONSTRAINT board_posts_pkey PRIMARY KEY (id);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: budget_backends budget_backends_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_backends
    ADD CONSTRAINT budget_backends_pkey PRIMARY KEY (id);


--
-- Name: calendar_contributors calendar_contributors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_contributors
    ADD CONSTRAINT calendar_contributors_pkey PRIMARY KEY (id);


--
-- Name: calendar_events calendar_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events
    ADD CONSTRAINT calendar_events_pkey PRIMARY KEY (id);


--
-- Name: capabilities capabilities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capabilities
    ADD CONSTRAINT capabilities_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: message_nodes message_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_nodes
    ADD CONSTRAINT message_nodes_pkey PRIMARY KEY (content_hash);


--
-- Name: missions missions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.missions
    ADD CONSTRAINT missions_pkey PRIMARY KEY (id);


--
-- Name: model_prices model_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_prices
    ADD CONSTRAINT model_prices_pkey PRIMARY KEY (model);


--
-- Name: model_roles model_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_roles
    ADD CONSTRAINT model_roles_pkey PRIMARY KEY (id);


--
-- Name: personas personas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personas
    ADD CONSTRAINT personas_pkey PRIMARY KEY (id);


--
-- Name: petitions petitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.petitions
    ADD CONSTRAINT petitions_pkey PRIMARY KEY (id);


--
-- Name: presets presets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.presets
    ADD CONSTRAINT presets_pkey PRIMARY KEY (id);


--
-- Name: principals principals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principals
    ADD CONSTRAINT principals_pkey PRIMARY KEY (id);


--
-- Name: prompt_snapshots prompt_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_snapshots
    ADD CONSTRAINT prompt_snapshots_pkey PRIMARY KEY (digest);


--
-- Name: providers providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);


--
-- Name: realms realms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.realms
    ADD CONSTRAINT realms_pkey PRIMARY KEY (slug);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sentinel_policies sentinel_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_policies
    ADD CONSTRAINT sentinel_policies_pkey PRIMARY KEY (id);


--
-- Name: sentinel_requests sentinel_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_requests
    ADD CONSTRAINT sentinel_requests_pkey PRIMARY KEY (id);


--
-- Name: todo_backends todo_backends_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.todo_backends
    ADD CONSTRAINT todo_backends_pkey PRIMARY KEY (id);


--
-- Name: usage_events usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT usage_events_pkey PRIMARY KEY (id);


--
-- Name: ward_checks ward_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_checks
    ADD CONSTRAINT ward_checks_pkey PRIMARY KEY (slug);


--
-- Name: ward_findings ward_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_findings
    ADD CONSTRAINT ward_findings_pkey PRIMARY KEY (id);


--
-- Name: ward_notes ward_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_notes
    ADD CONSTRAINT ward_notes_pkey PRIMARY KEY (id);


--
-- Name: ward_runs ward_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_runs
    ADD CONSTRAINT ward_runs_pkey PRIMARY KEY (id);


--
-- Name: index_agent_messages_on_inbox; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_messages_on_inbox ON public.agent_messages USING btree (recipient_id, read_at, created_at);


--
-- Name: index_agent_messages_on_recipient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_messages_on_recipient_id ON public.agent_messages USING btree (recipient_id);


--
-- Name: index_agent_messages_on_sender_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_messages_on_sender_id ON public.agent_messages USING btree (sender_id);


--
-- Name: index_agent_messages_on_sentinel_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_messages_on_sentinel_request_id ON public.agent_messages USING btree (sentinel_request_id);


--
-- Name: index_api_keys_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_keys_on_principal_id ON public.api_keys USING btree (principal_id);


--
-- Name: index_api_keys_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_keys_on_token_digest ON public.api_keys USING btree (token_digest);


--
-- Name: index_board_posts_on_sender_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_board_posts_on_sender_agent_id ON public.board_posts USING btree (sender_agent_id);


--
-- Name: index_board_posts_on_thread_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_board_posts_on_thread_id_and_created_at ON public.board_posts USING btree (thread_id, created_at);


--
-- Name: index_board_posts_on_thread_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_board_posts_on_thread_slug ON public.board_posts USING btree (thread_slug);


--
-- Name: index_branches_on_conversation_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_branches_on_conversation_id_and_name ON public.branches USING btree (conversation_id, name);


--
-- Name: index_budget_backends_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_budget_backends_on_name ON public.budget_backends USING btree (name);


--
-- Name: index_budget_backends_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_budget_backends_on_principal_id ON public.budget_backends USING btree (principal_id);


--
-- Name: index_calendar_contributors_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calendar_contributors_on_agent_id ON public.calendar_contributors USING btree (agent_id);


--
-- Name: index_calendar_contributors_on_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calendar_contributors_on_owner_id ON public.calendar_contributors USING btree (owner_id);


--
-- Name: index_calendar_contributors_on_owner_id_and_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calendar_contributors_on_owner_id_and_agent_id ON public.calendar_contributors USING btree (owner_id, agent_id);


--
-- Name: index_calendar_events_on_agent_owner_calendar_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calendar_events_on_agent_owner_calendar_uid ON public.calendar_events USING btree (source_agent_id, owner_id, calendar, uid);


--
-- Name: index_calendar_events_on_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calendar_events_on_owner_id ON public.calendar_events USING btree (owner_id);


--
-- Name: index_calendar_events_on_source_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calendar_events_on_source_agent_id ON public.calendar_events USING btree (source_agent_id);


--
-- Name: index_capabilities_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_capabilities_on_name ON public.capabilities USING btree (name);


--
-- Name: index_conversations_on_kind_and_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_kind_and_updated_at ON public.conversations USING btree (kind, updated_at);


--
-- Name: index_devices_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_principal_id ON public.devices USING btree (principal_id);


--
-- Name: index_devices_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_devices_on_token ON public.devices USING btree (token);


--
-- Name: index_message_nodes_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_message_nodes_on_conversation_id ON public.message_nodes USING btree (conversation_id);


--
-- Name: index_message_nodes_on_parent_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_message_nodes_on_parent_hash ON public.message_nodes USING btree (parent_hash);


--
-- Name: index_missions_on_assignee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_missions_on_assignee_id ON public.missions USING btree (assignee_id);


--
-- Name: index_missions_on_assignee_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_missions_on_assignee_queue ON public.missions USING btree (assignee_id, status, priority, created_at);


--
-- Name: index_missions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_missions_on_created_by_id ON public.missions USING btree (created_by_id);


--
-- Name: index_missions_on_sentinel_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_missions_on_sentinel_request_id ON public.missions USING btree (sentinel_request_id);


--
-- Name: index_model_roles_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_model_roles_on_role ON public.model_roles USING btree (role);


--
-- Name: index_personas_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_personas_on_key ON public.personas USING btree (key);


--
-- Name: index_petitions_on_capability_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_capability_name ON public.petitions USING btree (capability_name);


--
-- Name: index_petitions_on_decider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_decider_id ON public.petitions USING btree (decider_id);


--
-- Name: index_petitions_on_mission_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_mission_id ON public.petitions USING btree (mission_id);


--
-- Name: index_petitions_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_principal_id ON public.petitions USING btree (principal_id);


--
-- Name: index_petitions_on_principal_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_principal_id_and_created_at ON public.petitions USING btree (principal_id, created_at);


--
-- Name: index_petitions_on_sentinel_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_sentinel_policy_id ON public.petitions USING btree (sentinel_policy_id);


--
-- Name: index_petitions_on_status_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_petitions_on_status_and_created_at ON public.petitions USING btree (status, created_at);


--
-- Name: index_presets_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_presets_on_key ON public.presets USING btree (key);


--
-- Name: index_principals_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_principals_on_name ON public.principals USING btree (name);


--
-- Name: index_prompt_snapshots_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_snapshots_on_conversation_id ON public.prompt_snapshots USING btree (conversation_id);


--
-- Name: index_providers_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_providers_on_slug ON public.providers USING btree (slug);


--
-- Name: index_realms_on_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_realms_on_rank ON public.realms USING btree (rank);


--
-- Name: index_sentinel_policies_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_policies_on_principal_id ON public.sentinel_policies USING btree (principal_id);


--
-- Name: index_sentinel_policies_on_principal_id_and_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sentinel_policies_on_principal_id_and_capability ON public.sentinel_policies USING btree (principal_id, capability);


--
-- Name: index_sentinel_requests_on_capability_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_requests_on_capability_id ON public.sentinel_requests USING btree (capability_id);


--
-- Name: index_sentinel_requests_on_decider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_requests_on_decider_id ON public.sentinel_requests USING btree (decider_id);


--
-- Name: index_sentinel_requests_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_requests_on_principal_id ON public.sentinel_requests USING btree (principal_id);


--
-- Name: index_sentinel_requests_on_principal_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_requests_on_principal_id_and_created_at ON public.sentinel_requests USING btree (principal_id, created_at);


--
-- Name: index_sentinel_requests_on_status_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sentinel_requests_on_status_and_created_at ON public.sentinel_requests USING btree (status, created_at);


--
-- Name: index_todo_backends_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_todo_backends_on_name ON public.todo_backends USING btree (name);


--
-- Name: index_todo_backends_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_todo_backends_on_principal_id ON public.todo_backends USING btree (principal_id);


--
-- Name: index_usage_events_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_usage_events_on_created_at ON public.usage_events USING btree (created_at);


--
-- Name: index_usage_events_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_usage_events_on_principal_id ON public.usage_events USING btree (principal_id);


--
-- Name: index_usage_events_on_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_usage_events_on_ref ON public.usage_events USING btree (ref);


--
-- Name: index_usage_events_on_role_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_usage_events_on_role_and_created_at ON public.usage_events USING btree (role, created_at);


--
-- Name: index_ward_findings_on_acknowledged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_findings_on_acknowledged_by_id ON public.ward_findings USING btree (acknowledged_by_id);


--
-- Name: index_ward_findings_on_check_slug_and_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ward_findings_on_check_slug_and_fingerprint ON public.ward_findings USING btree (check_slug, fingerprint);


--
-- Name: index_ward_findings_on_check_slug_and_resolved_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_findings_on_check_slug_and_resolved_at ON public.ward_findings USING btree (check_slug, resolved_at);


--
-- Name: index_ward_notes_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_notes_on_author_id ON public.ward_notes USING btree (author_id);


--
-- Name: index_ward_notes_on_subject_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_notes_on_subject_and_created_at ON public.ward_notes USING btree (subject, created_at);


--
-- Name: index_ward_runs_on_check_slug_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_runs_on_check_slug_and_created_at ON public.ward_runs USING btree (check_slug, created_at);


--
-- Name: index_ward_runs_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ward_runs_on_principal_id ON public.ward_runs USING btree (principal_id);


--
-- Name: sentinel_policies fk_rails_038859ac35; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_policies
    ADD CONSTRAINT fk_rails_038859ac35 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: petitions fk_rails_1915a4ce8c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.petitions
    ADD CONSTRAINT fk_rails_1915a4ce8c FOREIGN KEY (sentinel_policy_id) REFERENCES public.sentinel_policies(id);


--
-- Name: ward_findings fk_rails_2b2f7cfe82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_findings
    ADD CONSTRAINT fk_rails_2b2f7cfe82 FOREIGN KEY (check_slug) REFERENCES public.ward_checks(slug);


--
-- Name: calendar_contributors fk_rails_2dc963feae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_contributors
    ADD CONSTRAINT fk_rails_2dc963feae FOREIGN KEY (owner_id) REFERENCES public.principals(id);


--
-- Name: board_posts fk_rails_43e63fa885; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.board_posts
    ADD CONSTRAINT fk_rails_43e63fa885 FOREIGN KEY (sender_agent_id) REFERENCES public.principals(id);


--
-- Name: sentinel_requests fk_rails_57f2dafd85; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_requests
    ADD CONSTRAINT fk_rails_57f2dafd85 FOREIGN KEY (decider_id) REFERENCES public.principals(id);


--
-- Name: petitions fk_rails_598ed31268; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.petitions
    ADD CONSTRAINT fk_rails_598ed31268 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: api_keys fk_rails_5a5e375519; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT fk_rails_5a5e375519 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: calendar_contributors fk_rails_609516a57a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_contributors
    ADD CONSTRAINT fk_rails_609516a57a FOREIGN KEY (agent_id) REFERENCES public.principals(id);


--
-- Name: missions fk_rails_6e053f8b2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.missions
    ADD CONSTRAINT fk_rails_6e053f8b2f FOREIGN KEY (assignee_id) REFERENCES public.principals(id);


--
-- Name: ward_runs fk_rails_79a2267124; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_runs
    ADD CONSTRAINT fk_rails_79a2267124 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: ward_notes fk_rails_7e3b5c0498; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_notes
    ADD CONSTRAINT fk_rails_7e3b5c0498 FOREIGN KEY (author_id) REFERENCES public.principals(id);


--
-- Name: calendar_events fk_rails_8319b541ce; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events
    ADD CONSTRAINT fk_rails_8319b541ce FOREIGN KEY (owner_id) REFERENCES public.principals(id);


--
-- Name: devices fk_rails_8b23b306c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_8b23b306c0 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: agent_messages fk_rails_92352b2e86; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_messages
    ADD CONSTRAINT fk_rails_92352b2e86 FOREIGN KEY (sender_id) REFERENCES public.principals(id);


--
-- Name: ward_findings fk_rails_9b38963c63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_findings
    ADD CONSTRAINT fk_rails_9b38963c63 FOREIGN KEY (acknowledged_by_id) REFERENCES public.principals(id);


--
-- Name: calendar_events fk_rails_a15b711368; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events
    ADD CONSTRAINT fk_rails_a15b711368 FOREIGN KEY (source_agent_id) REFERENCES public.principals(id);


--
-- Name: sentinel_requests fk_rails_aed65976d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_requests
    ADD CONSTRAINT fk_rails_aed65976d5 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: ward_runs fk_rails_b03399b877; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ward_runs
    ADD CONSTRAINT fk_rails_b03399b877 FOREIGN KEY (check_slug) REFERENCES public.ward_checks(slug);


--
-- Name: budget_backends fk_rails_b4d50361d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_backends
    ADD CONSTRAINT fk_rails_b4d50361d3 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: todo_backends fk_rails_c0b35bfef2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.todo_backends
    ADD CONSTRAINT fk_rails_c0b35bfef2 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: petitions fk_rails_ca627f2e79; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.petitions
    ADD CONSTRAINT fk_rails_ca627f2e79 FOREIGN KEY (decider_id) REFERENCES public.principals(id);


--
-- Name: agent_messages fk_rails_e59b64cbcb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_messages
    ADD CONSTRAINT fk_rails_e59b64cbcb FOREIGN KEY (recipient_id) REFERENCES public.principals(id);


--
-- Name: sentinel_requests fk_rails_edda5c50a5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentinel_requests
    ADD CONSTRAINT fk_rails_edda5c50a5 FOREIGN KEY (capability_id) REFERENCES public.capabilities(id);


--
-- Name: usage_events fk_rails_efdc5578b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_rails_efdc5578b2 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: missions fk_rails_f765c80df4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.missions
    ADD CONSTRAINT fk_rails_f765c80df4 FOREIGN KEY (created_by_id) REFERENCES public.principals(id);


--
-- Name: board_posts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.board_posts ENABLE ROW LEVEL SECURITY;

--
-- Name: budget_backends; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.budget_backends ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: message_nodes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.message_nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: missions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.missions ENABLE ROW LEVEL SECURITY;

--
-- Name: petitions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.petitions ENABLE ROW LEVEL SECURITY;

--
-- Name: prompt_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prompt_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: board_posts realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.board_posts USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (board_posts.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: budget_backends realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.budget_backends USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (budget_backends.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: conversations realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.conversations USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (conversations.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: message_nodes realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.message_nodes USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (message_nodes.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: missions realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.missions USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (missions.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: petitions realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.petitions USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (petitions.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: prompt_snapshots realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.prompt_snapshots USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (prompt_snapshots.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: sentinel_requests realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.sentinel_requests USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (sentinel_requests.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: todo_backends realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.todo_backends USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (todo_backends.realm)::text)) <= public.app_clearance_rank()));


--
-- Name: sentinel_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sentinel_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: todo_backends; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.todo_backends ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260924190500'),
('20260924190000'),
('20260924180000'),
('20260924170000'),
('20260921000002'),
('20260921000001'),
('20260920063000'),
('20260920000003'),
('20260920000002'),
('20260920000001'),
('20260919185000'),
('20260919000001'),
('20260918000001'),
('20260915000001'),
('20260906000001'),
('20260718000002'),
('20260718000001');

