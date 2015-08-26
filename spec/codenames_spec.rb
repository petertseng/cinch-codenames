require 'simplecov'
SimpleCov.start { add_filter '/spec/' }

require 'cinch/test'
require 'cinch/plugins/codenames'

def get_replies_text(m)
  replies = get_replies(m)
  # If you wanted, you could read all the messages as they come, but that might be a bit much.
  # You'd want to check the messages of user1, user2, and chan as well.
  # replies.each { |x| puts(x.text) }
  replies.map(&:text)
end

class MessageReceiver
  attr_reader :name
  attr_accessor :messages

  def initialize(name)
    @name = name
    @messages = []
  end

  def send(m)
    @messages << m
  end
end

class TestChannel < MessageReceiver
  def voiced
    []
  end
  def devoice(_)
  end
  def moderated=(_)
  end
end

RSpec.describe Cinch::Plugins::Codenames do
  include Cinch::Test

  let(:channel1) { '#test' }
  let(:chan) { TestChannel.new(channel1) }
  let(:player1) { 'test1' }
  let(:player2) { 'test2' }
  let(:player3) { 'test3' }
  let(:player4) { 'test4' }
  let(:npmod) { 'npmod' }
  let(:players) { [
    player1,
    player2,
    player3,
    player4,
  ]}

  let(:opts) {{
    :channels => [channel1],
    :settings => '/dev/null',
    :mods => [npmod, player1],
    :allowed_idle => 300,
    :words => (1..25).map { |i| "word#{i}" }
  }}
  let(:bot) {
    b = make_bot(described_class, opts) { |c|
      self.loggers.first.level = :warn
    }
    # No, c.nick = 'testbot' doesn't work because... isupport?
    allow(b).to receive(:nick).and_return('testbot')
    b
  }
  let(:plugin) { bot.plugins.first }

  def msg(text, nick: player1, channel: channel1)
    make_message(bot, text, nick: nick, channel: channel)
  end
  def authed_msg(text, nick: player1, channel: channel1)
    m = msg(text, nick: nick, channel: channel)
    allow(m.user).to receive(:authed?).and_return(true)
    allow(m.user).to receive(:authname).and_return(nick)
    m
  end

  def join(message)
    expect(message.channel).to receive(:has_user?).with(message.user).and_return(true)
    expect(message.channel).to receive(:voice).with(message.user)
    get_replies(message)
  end

  # This is very bad, but cinch-test doesn't natively allow catching arbitrary player messages.
  def catch_player_messages(player, messages, strict: true)
    user = plugin.instance_variable_get('@games')[channel1].send(:find_player, player).user
    if strict
      expect(user).to receive(:send) { |x| messages << x }
    else
      allow(user).to receive(:send) { |x| messages << x }
    end
  end

  it 'makes a test bot' do
    expect(bot).to be_a(Cinch::Bot)
  end

  describe 'team preferences' do
    before :each do
      join(msg('!join', nick: player1))
    end

    it 'allows team A' do
      expect(get_replies_text(msg('!team a'))).to be == ["#{player1}: You joined team A."]
    end

    it 'allows team B' do
      expect(get_replies_text(msg('!team b'))).to be == ["#{player1}: You joined team B."]
    end

    it 'allows team R' do
      expect(get_replies_text(msg('!team r'))).to be == ["#{player1}: You joined team Random."]
    end

    it 'allows team X' do
      expect(get_replies_text(msg('!team x'))).to be == ["#{player1}: You joined team Random."]
    end

    it 'shows the teams' do
      get_replies_text(msg('!team a'))
      cleaned_messages = get_replies_text(msg('!teams')).map { |x|
        x.tr(8203.chr('UTF-8'), '')
      }
      expect(cleaned_messages).to be == ["Team A (1): #{player1}"]
    end
  end

  context 'in a game' do
    before :each do
      players.each { |player| join(msg('!join', nick: player)) }
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
      get_replies(msg('!start'))
    end

    it 'welcomes the players' do
      expect(chan.messages).to_not be_empty
      expect(chan.messages).to be_any { |x| x =~ /welcome/i }
    end

    # A little fragile, but the best we can do.
    let(:teams) {
      txt = get_replies_text(msg('!status')).find { |text| text.include?(player1) }
      matches = %r{\((\w+), (\w+)\).*\((\w+), (\w+)\)}.match(txt).captures
      [matches[0..1], matches[2..3]]
    }
    let(:hinters) { teams.map { |p| p[0] } }
    let(:guessers) { teams.map { |p| p[1] } }

    it 'has no words yet' do
      expect(get_replies(msg('!words'))).to be_empty
    end

    it 'shows teams' do
      # TODO better check?
      expect(get_replies(msg('!teams'))).to_not be_empty
    end

    it 'shows status' do
      replies = get_replies_text(msg('!status'))
      expect(replies).to be_all { |x| x.include?("choosing a #{::Codenames::Text::ROLES[:hint]}") }
      expect(replies.drop(1)).to be_empty
    end

    it 'allows players to volunteer as hinter' do
      role_name = ::Codenames::Text::ROLES[:hint]
      expect(get_replies_text(msg('!me', nick: hinters[0]))).to be_all { |x| x.include?("#{role_name} is") }

      chan.messages.clear
      hinter_messages = []
      catch_player_messages(hinters[0], hinter_messages)

      expect(get_replies_text(msg('!me', nick: hinters[1]))).to be_all { |x| x.include?("#{role_name} is") }

      expect(chan.messages).to be_any { |x| x.include?('Codenames for game') }
      expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
      expect(hinter_messages).to be_any { |x| x.include?('status') }
    end

    it 'allows random hinters' do
      role_name = ::Codenames::Text::ROLES[:hint]
      expect(get_replies_text(msg('!random', nick: hinters[0]))).to be_all { |x| x.include?("#{role_name} is") }

      chan.messages.clear
      hinter_messages = []
      # Since it's random, the "guesser" might be the hinter...
      catch_player_messages(hinters[0], hinter_messages, strict: false)
      catch_player_messages(guessers[0], hinter_messages, strict: false)

      expect(get_replies_text(msg('!random', nick: hinters[1]))).to be_all { |x| x.include?("#{role_name} is") }

      expect(chan.messages).to be_any { |x| x.include?('Codenames for game') }
      expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
      expect(hinter_messages).to be_any { |x| x.include?('status') }
    end

    context 'when roles are decided' do
      before(:each) do
        get_replies(msg('!me', nick: hinters[0]))
        get_replies(msg('!me', nick: hinters[1]))
        chan.messages.clear
      end

      it 'shows words to guessers' do
        # TODO better check?
        expect(get_replies(msg('!words', nick: guessers[0])).size).to be == 1
      end

      it 'shows hinter info to hinters' do
        # TODO better check?
        expect(get_replies(msg('!words', nick: hinters[0])).size).to be == 1
      end

      it 'shows teams' do
        # TODO better check?
        expect(get_replies(msg('!teams'))).to_not be_empty
      end

      it 'prompts player who forgets a clue number' do
        expect(get_replies_text(msg('!clue hi', nick: hinters[0]))).to be_any { |x|
          x.include?('invalid number')
        }
      end

      it 'prompts for guesses in response to a clue' do
        get_replies(msg('!clue hi 2', nick: hinters[0]))
        expect(chan.messages).to be_any { |x| x.include?('status') }
        expect(chan.messages).to be_any { |x| x.include?('Please make a !guess') }
      end

      it 'prompts for guesses in response to an unlimited clue' do
        get_replies(msg('!clue hi unlimited', nick: hinters[0]))
        expect(chan.messages).to be_any { |x| x.include?('status') }
        expect(chan.messages).to be_any { |x| x.include?('Please make a !guess') }
      end

      it 'prompts for guesses in response to a zero clue' do
        get_replies(msg('!clue hi 0', nick: hinters[0]))
        expect(chan.messages).to be_any { |x| x.include?('status') }
        expect(chan.messages).to be_any { |x| x.include?('Please make a !guess') }
      end
    end

    context 'when hint is given' do
      before(:each) do
        get_replies(msg('!me', nick: hinters[0]))
        get_replies(msg('!me', nick: hinters[1]))
        get_replies(msg('!clue hi 1', nick: hinters[0]))
        chan.messages.clear
      end

      # This is pretty bad.
      let(:words) { get_replies_text(msg('!words', nick: hinters[0])).find { |x| x.include?('Assassin') } }
      let(:team0_word) { %r{\(9\): (\w+)}.match(words)[1] }
      let(:team0_word2) { %r{\(9\): \w+, (\w+)}.match(words)[1] }
      let(:team1_word) { %r{\(8\): (\w+)}.match(words)[1] }
      let(:neutral_word) { %r{\(7\): (\w+)}.match(words)[1] }
      let(:assassin_word) { %r{\(1\): (\w+)}.match(words)[1] }

      it 'rejects an immediate skip' do
        expect(get_replies_text(msg('!stop', nick: guessers[0]))).to be_any { |x|
          x.include?('must make at least one guess')
        }
      end

      it 'ends game on guessing assassin' do
        get_replies(msg("!guess #{assassin_word}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x =~ %r{Blue.*loses} }
        expect(chan.messages).to be_any { |x| x.include?('Congratulations!!!') }
      end

      it 'ends turn on guessing neutral' do
        hinter_messages = []
        catch_player_messages(hinters[1], hinter_messages)

        get_replies(msg("!guess #{neutral_word}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x.include?('turn is over') }
        expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
        expect(hinter_messages).to be_any { |x| x.include?('status') }
      end

      it 'ends turn on guessing other team' do
        hinter_messages = []
        catch_player_messages(hinters[1], hinter_messages)

        get_replies(msg("!guess #{team1_word}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x.include?('turn is over') }
        expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
        expect(hinter_messages).to be_any { |x| x.include?('status') }
      end

      it 'continues turn on guessing own team' do
        get_replies(msg("!guess #{team0_word}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x.include?('can continue guessing') }
        expect(chan.messages).to be_any { |x| x.include?('Please make a !guess') }
      end

      it 'ends turn when out of guesses' do
        get_replies(msg("!guess #{team0_word}", nick: guessers[0]))

        chan.messages.clear
        hinter_messages = []
        catch_player_messages(hinters[1], hinter_messages)

        get_replies(msg("!guess #{team0_word2}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x.include?('turn is over') }
        expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
        expect(hinter_messages).to be_any { |x| x.include?('status') }
      end

      it 'allows all players to join a second game' do
        get_replies(msg("!guess #{assassin_word}", nick: guessers[0]))
        players.each { |player|
          expect(join(msg('!join', nick: player))).to be_any { |x|
            x.text.include?('has joined the game')
          }
        }
      end

      it 'allows a skip after a correct guess' do
        get_replies(msg("!guess #{team0_word}", nick: guessers[0]))

        chan.messages.clear
        hinter_messages = []
        catch_player_messages(hinters[1], hinter_messages)

        get_replies(msg('!stop', nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
        expect(hinter_messages).to be_any { |x| x.include?('status') }
      end
    end

    context 'when unlimited hint is given' do
      before(:each) do
        get_replies(msg('!me', nick: hinters[0]))
        get_replies(msg('!me', nick: hinters[1]))
        get_replies(msg('!clue hi unlimited', nick: hinters[0]))
        chan.messages.clear
      end

      # This is pretty bad.
      let(:words) { get_replies_text(msg('!words', nick: hinters[0])).find { |x| x.include?('Assassin') } }
      let(:team0_words) { %r{\(9\): ([\w, ]+)$}.match(words)[1].split(', ') }

      it 'ends the game when all words are guessed' do
        team0_words.drop(1).each { |word| get_replies(msg("!guess #{word}", nick: guessers[0])) }
        chan.messages.clear
        get_replies(msg("!guess #{team0_words.first}", nick: guessers[0]))
        expect(chan.messages).to be_any { |x| x =~ %r{Blue.*all their agents} }
        expect(chan.messages).to be_any { |x| x.include?('Congratulations!!!') }
      end
    end

    describe 'reset' do
      it 'lets a mod reset' do
        chan.messages.clear
        get_replies_text(authed_msg('!reset', nick: player1))
        expect(chan.messages).to be_any { |x| x.include?('reset') }
      end

      it 'shows info if game was going on' do
        get_replies(msg('!me', nick: hinters[0]))
        get_replies(msg('!me', nick: hinters[1]))
        chan.messages.clear
        get_replies_text(authed_msg('!reset', nick: player1))
        expect(chan.messages).to be_any { |x| x.include?('words') }
        expect(chan.messages).to be_any { |x| x.include?('reset') }
      end

      it 'does not respond to a non-mod' do
        chan.messages.clear
        get_replies_text(authed_msg('!reset', nick: player2))
        expect(chan.messages).to be_empty
      end
    end

    describe 'peek' do
      it 'calls a playing mod a cheater' do
        expect(get_replies_text(authed_msg('!peek', nick: player1))).to be == ['Cheater!!!']
      end

      it 'does not respond to a non-mod' do
        expect(get_replies_text(authed_msg('!peek', nick: player2))).to be_empty
      end

      it 'shows info to a non-playing mod' do
        replies = get_replies_text(authed_msg("!peek #{channel1}", nick: npmod))
        expect(replies).to_not be_empty
        expect(replies).to_not be_any { |x| x =~ /cheater/i }
      end
    end
  end

  context 'in a three-player game' do
    before :each do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      join(msg('!join', nick: player3))
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
      get_replies(msg('!start'))
    end

    it 'welcomes the players' do
      expect(chan.messages).to_not be_empty
      expect(chan.messages).to be_any { |x| x =~ /welcome/i }
      expect(chan.messages).to be_any { |x| x.include?('Codenames for game') }
      expect(chan.messages).to be_any { |x| x.include?('Please present a !clue') }
    end

    it 'has words yet' do
      expect(get_replies(msg('!words'))).to_not be_empty
    end

    it 'shows teams' do
      # TODO better check?
      expect(get_replies(msg('!teams'))).to_not be_empty
    end

    it 'shows status' do
      replies = get_replies_text(msg('!status'))
      expect(replies).to be_all { |x| x.include?('Please present a !clue') }
      expect(replies.drop(1)).to be_empty
    end
  end

  describe 'status' do
    it 'responds with no players' do
      replies = get_replies_text(msg('!status', channel: channel1))
      expect(replies).to be_all { |x| x =~ /no game/i }
      expect(replies.drop(1)).to be_empty
    end

    it 'responds with one player' do
      join(msg('!join'))
      replies = get_replies_text(msg('!status', channel: channel1))
      expect(replies).to be_all { |x| x =~ /1 player/i }
      expect(replies.drop(1)).to be_empty
    end
  end

  describe 'help' do
    let(:help_replies) {
      get_replies_text(make_message(bot, '!help', nick: player1))
    }

    it 'responds to !help' do
      expect(help_replies).to_not be_empty
    end

    it 'responds differently to !help 2' do
      replies2 = get_replies_text(make_message(bot, '!help 2', nick: player1))
      expect(replies2).to_not be_empty
      expect(help_replies).to_not be == replies2
    end

    it 'responds differently to !help 3' do
      replies3 = get_replies_text(make_message(bot, '!help 3', nick: player1))
      expect(replies3).to_not be_empty
      expect(help_replies).to_not be == replies3
    end

    it 'responds differently to !help mod from a mod' do
      replies_mod = get_replies_text(authed_msg('!help mod', nick: player1))
      expect(replies_mod).to_not be_empty
      expect(help_replies).to_not be == replies_mod
    end

    it 'responds like !help to !help mod from a non-mod' do
      replies_normal = get_replies_text(authed_msg('!help', nick: player2))
      replies_mod2 = get_replies_text(authed_msg('!help mod', nick: player2))
      expect(replies_mod2).to_not be_empty
      expect(replies_normal).to be == replies_mod2
    end
  end

  describe 'rules' do
    it 'responds to !rules' do
      expect(get_replies_text(make_message(bot, '!rules', nick: player1))).to_not be_empty
    end
  end
end
