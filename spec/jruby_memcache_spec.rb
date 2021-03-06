require 'java'
require File.dirname(__FILE__) + '/../lib/memcache'

describe MemCache do

  before :all do
    @server = "127.0.0.1:11211"
  end

  before :each do
    @client = MemCache.new @server
    @client.should_not be_nil
    @client.flush_all
  end

  after :each do
    @client.flush_all
  end

  it "should return nil for a non-existent key" do
    @client.read('non-existent-key').should be_nil
  end

  describe "setting servers" do
    it "should work if the instance is created with a single String argument" do
      @client = MemCache.new @server
      @client.servers.should == [@server]
    end

    it "should work if the instance is created with an Array" do
      @client = MemCache.new [ @server ]
      @client.servers.should == [@server]
    end

    it "should work if the instance is created with a Hash" do
      @client = MemCache.new [ @server ], :namespace => 'test'
      @client.servers.should == [@server]
    end

    it "should work with an explicit pool name" do
      @client = MemCache.new([@server], :pool_name => 'new_pool')
      @client.pool_name.should == 'new_pool'
    end

    it "should work with an error handler" do
      include_class 'com.danga.MemCached.MemCachedClient'
      java_memcache_client = mock.as_null_object
      MemCachedClient.stub!(:new => java_memcache_client)
      error_handler = Object.new
      java_memcache_client.should_receive(:error_handler=).with(error_handler)
      @client = MemCache.new([@server], :error_handler => error_handler)
    end
  end

  describe "namespacing" do
    before(:each) do
      @ns = 'namespace'
      @nsclient = MemCache.new [ @server ] , :namespace => @ns
      @nsclient.flush_all
      @nsclient.write "test", 333, 0
    end

    it "should write and read values transparently" do
      @nsclient.read("test").should == 333
    end

    it "should write values to the given namespace" do
      @nsclient.read("test").to_i.should == 333
    end

    it "should not write a value without the given namespace" do
      @client.read("test").to_i.should_not == 333
    end

    it "should delete values in the given namespace" do
      @nsclient.delete "test"
      @nsclient.read("test").should be_nil
    end

    it "should increment in the given namespace" do
      @nsclient.incr("test").to_i.should == 334
    end

    it "should decrement values in the given namespace" do
      @nsclient.decr("test").should == 332
    end
  end

  describe "after writing a value to MemCache" do
    before(:each) do
      @client.write 'key', 'value'
    end

    it "should be able to retrieve the value" do
      @client.read('key').should == 'value'
    end

    it "should not be able to retrieve the value after deleting" do
      @client.delete('key')
      @client.read('key').should be_nil
    end

    it "should not be able to retrieve the value after flushing everything" do
      @client.flush_all
      @client.read("key").should be_nil
    end
  end

  describe "using write with if_exist" do
    before :each do
      @client.write('key', 'value')
    end

    it "should be able to write the stored value." do
      @client.write('key', 'new value', :if_exist => true).should be_true
      @client.read('key').should == 'new value'
    end

    it "should not write values that are not in the cache." do
      @client.write('notthere', 'value', :if_exist => true).should be_false
    end
  end

  describe "#fetch" do
    before :each do
      @client.write('key', 'value')
    end

    it "should read the value from cache." do
      @client.fetch('key') { 'new value' }.should == 'value'
    end

    it "should write value to cache with force" do
      @client.fetch('key', :force => true) { 'new value' }.should == 'new value'
    end

    it "should write value to cache with expires_in and force" do
      @client.fetch('key', :expires_in => 2, :force => true) { 'new value' }
      sleep 3
      @client.read('key').should be_nil
    end
  end

  describe "#stats" do
    it "should return a hash" do
      @client.stats.should be_instance_of(Hash)
    end

    it "should return a float for rusage_system and rusage_user" do
      @client.stats[@server]['rusage_system'].should be_instance_of(Float)
      @client.stats[@server]['rusage_user'].should be_instance_of(Float)
    end

    it "should return a String for version" do
      @client.stats[@server]['version'].should be_instance_of(String)
    end
  end

  describe "#exist?" do
    it "should return false if no such key" do
      @client.exist?('non_exist').should be_false
    end

    it "should return true if the key is already existed" do
      @client.write 'exist', 'str'
      @client.exist?('exist').should be_true
    end
  end

  describe "#incr" do
    it "should increment a value by 1 without a second parameter" do
      @client.write 'incr', 100, 0
      @client.incr 'incr'
      @client.read('incr').to_i.should == 101
    end

    it "should increment a value by a given second parameter" do
      @client.write 'incr', 100, 0
      @client.incr 'incr', 20
      @client.read('incr').to_i.should == 120
    end
  end

  describe "#decr" do

    it "should decrement a value by 1 without a second parameter" do
      @client.write 'decr', 100, 0
      @client.decr 'decr'
      @client.read('decr').to_i.should == 99
    end

    it "should decrement a value by a given second parameter" do
      @client.write 'decr', 100, 0
      @client.decr 'decr', 20
      @client.read('decr').to_i.should == 80
    end
  end

  describe "with Ruby Objects" do
    it "should be able to transparently write and read equivalent Ruby objects" do
      obj = { :test => :hi }
      @client.write('obj', obj)
      @client.read('obj').should == obj
    end

    it %[should work with those whose marshalled stream contains invalid UTF8 byte sequences] do
      # this test fails w/o the Base64 encoding step
      obj = { :foo => 900 }
      @client.write('obj', obj)
      @client.read('obj').should == obj
    end

    it %[should work with binary blobs] do
      # this test fails w/o the Base64 encoding step
      blob = "\377\330\377\340\000\020JFIF\000\001\001\000\000\001\000\001\000\000\377"
      @client.write('blob', blob)
      @client.read('blob').should == blob
    end
  end

  describe "using write with an expiration" do
    it "should make a value unretrievable if the expiry is write to a negative value" do
      @client.write('key', 'val', :expires_in => -1)
      @client.read('key').should be_nil
    end

    it "should make a value retrievable for only the amount of time if a value is given" do
      @client.write('key', 'val', :expires_in => 2)
      @client.read('key').should == 'val'
      sleep(3)
      @client.read('key').should be_nil
    end
  end

  describe "using write with unless_exist" do
    before do
      @client.write('key', 'val')
    end

    it "should not make a value if unless_exist is true" do
      @client.write('key', 'new_val', :unless_exist => true)
      @client.read('key').should == 'val'
    end

    it "should make a value if unless_exist is false" do
      @client.write('key', 'new_val', :unless_exist => false)
      @client.read('key').should == 'new_val'
    end
  end

  describe "#read_multi" do
    it "should read 2 keys" do
      @client.write('key', 'val')
      @client.write('key2', 'val2')
      @client.read_multi(%w/key key2/).should == {'key' => 'val', 'key2' => 'val2'}
    end

    it "should ignore nil values" do
      @client.write('key', 'val')
      @client.write('key2', 'val2')
      @client.read_multi(%w/key key2 key3/).should == {'key' => 'val', 'key2' => 'val2'}
    end

    it "should not marshall if requested" do
      @client.write('key', 'val', :raw => true)
      @client.write('key2', 'val2', :raw => true)
      @client.read_multi(%w/key key2/, :raw => true).should == {'key' => 'val', 'key2' => 'val2'}
    end
  end

  describe "aliveness of the MemCache server." do
    before :each do
      @servers = ["localhost:11211", "localhost:11212", {:pool_name => "test"}]
      @client = MemCache.new @servers
      @client.flush_all
    end

    it "should report the client as being alive." do
      @client.should be_alive
    end

    it "should report localhost:11211 as being alive." do
      servers = @client.servers
      servers.first.should be_alive
    end

    it "should report localhost:11212 as not being alive." do
      servers = @client.servers
      servers.find {|s| s.to_s == "localhost:11212"}.should be_nil
    end
  end
end

