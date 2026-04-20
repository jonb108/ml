drop table if exists messages; 
create table messages (
    id int(11) primary key auto_increment,
    message varchar(512),
    mdate varchar(8),
    topics_desc varchar(512),
    brigade_name varchar(256),
    city varchar(128),
    state varchar(8)
);

drop table if exists topics; 
create table topics (
    id int(11) primary key auto_increment,
    description varchar(256),
    count int(11)
);

drop table if exists message_topic;
create table message_topic (
    message_id int(11),
    topic_id int(11)
);
