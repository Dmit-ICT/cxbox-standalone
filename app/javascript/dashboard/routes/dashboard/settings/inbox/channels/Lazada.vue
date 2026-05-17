<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      appProfileKey: '',
      appProfileSecret: '',
      appChatKey: '',
      appChatSecret: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    appProfileKey: { required },
    appProfileSecret: { required },
    appChatKey: { required },
    appChatSecret: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const lazadaChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'lazada',
              app_profile_key: this.appProfileKey,
              app_profile_secret: this.appProfileSecret,
              app_chat_key: this.appChatKey,
              app_chat_secret: this.appChatSecret,
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: lazadaChannel.id,
          },
        });
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.ADD.LAZADA_CHANNEL.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.LAZADA_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.LAZADA_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
            "
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appProfileKey.$error }">
          {{ $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_PROFILE_KEY.LABEL') }}
          <input
            v-model="appProfileKey"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_PROFILE_KEY.PLACEHOLDER')
            "
            @blur="v$.appProfileKey.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appProfileSecret.$error }">
          {{ $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_PROFILE_SECRET.LABEL') }}
          <input
            v-model="appProfileSecret"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_PROFILE_SECRET.PLACEHOLDER')
            "
            @blur="v$.appProfileSecret.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appChatKey.$error }">
          {{ $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_CHAT_KEY.LABEL') }}
          <input
            v-model="appChatKey"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_CHAT_KEY.PLACEHOLDER')
            "
            @blur="v$.appChatKey.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appChatSecret.$error }">
          {{ $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_CHAT_SECRET.LABEL') }}
          <input
            v-model="appChatSecret"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.LAZADA_CHANNEL.APP_CHAT_SECRET.PLACEHOLDER')
            "
            @blur="v$.appChatSecret.$touch"
          />
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.LAZADA_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
