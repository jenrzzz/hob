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
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


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
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id character varying NOT NULL,
    surface character varying NOT NULL,
    realm character varying NOT NULL,
    taint_realm character varying NOT NULL,
    title character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.conversations FORCE ROW LEVEL SECURITY;


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
-- Name: principals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.principals (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    name character varying NOT NULL,
    max_clearance character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
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
    created_at timestamp(6) without time zone NOT NULL
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
-- Name: api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys ALTER COLUMN id SET DEFAULT nextval('public.api_keys_id_seq'::regclass);


--
-- Name: branches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches ALTER COLUMN id SET DEFAULT nextval('public.branches_id_seq'::regclass);


--
-- Name: model_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_roles ALTER COLUMN id SET DEFAULT nextval('public.model_roles_id_seq'::regclass);


--
-- Name: principals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principals ALTER COLUMN id SET DEFAULT nextval('public.principals_id_seq'::regclass);


--
-- Name: providers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers ALTER COLUMN id SET DEFAULT nextval('public.providers_id_seq'::regclass);


--
-- Name: usage_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ALTER COLUMN id SET DEFAULT nextval('public.usage_events_id_seq'::regclass);


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
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: message_nodes message_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_nodes
    ADD CONSTRAINT message_nodes_pkey PRIMARY KEY (content_hash);


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
-- Name: usage_events usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT usage_events_pkey PRIMARY KEY (id);


--
-- Name: index_api_keys_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_keys_on_principal_id ON public.api_keys USING btree (principal_id);


--
-- Name: index_api_keys_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_keys_on_token_digest ON public.api_keys USING btree (token_digest);


--
-- Name: index_branches_on_conversation_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_branches_on_conversation_id_and_name ON public.branches USING btree (conversation_id, name);


--
-- Name: index_message_nodes_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_message_nodes_on_conversation_id ON public.message_nodes USING btree (conversation_id);


--
-- Name: index_message_nodes_on_parent_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_message_nodes_on_parent_hash ON public.message_nodes USING btree (parent_hash);


--
-- Name: index_model_roles_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_model_roles_on_role ON public.model_roles USING btree (role);


--
-- Name: index_personas_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_personas_on_key ON public.personas USING btree (key);


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
-- Name: index_usage_events_on_principal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_usage_events_on_principal_id ON public.usage_events USING btree (principal_id);


--
-- Name: api_keys fk_rails_5a5e375519; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT fk_rails_5a5e375519 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: usage_events fk_rails_efdc5578b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_rails_efdc5578b2 FOREIGN KEY (principal_id) REFERENCES public.principals(id);


--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: message_nodes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.message_nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: prompt_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prompt_snapshots ENABLE ROW LEVEL SECURITY;

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
-- Name: prompt_snapshots realm_visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY realm_visibility ON public.prompt_snapshots USING ((( SELECT realms.rank
   FROM public.realms
  WHERE ((realms.slug)::text = (prompt_snapshots.realm)::text)) <= public.app_clearance_rank()));


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260718000001');

